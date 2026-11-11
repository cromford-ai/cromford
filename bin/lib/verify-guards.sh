#!/bin/bash
# bin/lib/verify-guards.sh — the always-run guard suites of a project, for the
# pre-push suite run (BH-9414 slice C0). Sourced, never executed. Functions only.
#
# WHY. HARNESS_SUITE_RUN (bin/lib/rb/gates.sh) runs only the unit files
# bin/lib/test-select.sh picks for the diff. That selector reads the guards in
# tests/static-guards.txt and tests/static-guards/, but a project can declare its
# always-run guards in another file: project-6 keeps them in
# scripts/ci/lane-rules.json `alwaysSuites` (TK-3641). Its CI ran the tenancy
# guard on PR #3662 and went red; the box run had not run that guard.
#
# CONTRACT
#   vg_list <repo> <head>
#       stdout: the guard test paths, one per line, each a file in the <head>
#       tree, sorted and de-duplicated (LC_ALL=C sort -u). Sources, in order:
#         1. each entry of the knob VERIFY_GUARD_SOURCES (comma list):
#            `<file>`        a text file, one path or glob per line, `#` comments;
#            `<file>#<key>`  a JSON file; <key> is an array of path strings.
#            A source file absent at <head> is skipped. A JSON file with no
#            <key> is skipped. Only <key> is read (never `alwaysFull`).
#         2. every file under tests/static-guards/ at <head>.
#       A path is dropped when it is empty, starts with `-` or `/`, has a `..`
#       part, carries CR or LF, has an `e2e` path part (the box never runs E2E),
#       or is not a file in the <head> tree (an untracked file does not count).
#       A glob entry (`*`, `?`, `[`) adds each file in the <head> tree it matches.
#       rc 0  the list (it can be empty).
#       rc 2  more paths than the knob VERIFY_GUARD_MAX: nothing on stdout.
#       rc 3  a source cannot be parsed (bad JSON, <key> not an array of
#             strings, no jq): nothing on stdout, one `UNREADABLE: <why>` line
#             on stderr.
#   vg_suite_guards <repo> <head>
#       rc 0  VG_GUARDS=(the list), VG_WHY="".
#       rc 2  VG_GUARDS=(), VG_WHY=<why the list cannot be used>. The caller
#             widens the run to FULL; it never narrows it.
#
# Knobs: VERIFY_GUARD_SOURCES, VERIFY_GUARD_MAX (catalog/lanes.d/_lib.verify-guards.json,
# rows lib.verify-guards[.<project>].verify_guard_sources / .verify_guard_max).
# The defaults live only in that fragment.
#
# The sources are PR-controlled input. They are parsed with jq and `case` only,
# and each path goes to npm as one argv item. No eval, no `bash -c`.

_VG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _vg_default <ENV> — the fragment default, for a caller with no registry.
_vg_default() {
  local f root="${HARNESS:-}"
  for f in ${root:+"$root/catalog/lanes.d/_lib.verify-guards.json"} "$_VG_LIB/../../catalog/lanes.d/_lib.verify-guards.json"; do
    [ -r "$f" ] || continue
    jq -r --arg e "$1" '[.libs[]?.knobs[]? | select(.env == $e) | .default][0] // empty | tostring' "$f" 2>/dev/null
    return 0
  done
}

# _vg_knob <ENV> — lane_knob in libs scope (with $PROJECT), else the harness
# lane-gate.sh in a subshell, else the env, else the fragment default.
_vg_knob() {
  local _LG_KIND=libs v="" root="${HARNESS:-}" lg
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob verify-guards "$1" "${PROJECT:-}" 2>/dev/null)
  else
    for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$_VG_LIB/lane-gate.sh"; do
      [ -r "$lg" ] || continue
      v=$( . "$lg" 2>/dev/null && _LG_KIND=libs lane_knob verify-guards "$1" "${PROJECT:-}" 2>/dev/null )
      break
    done
  fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v=$(_vg_default "$1")
  printf '%s' "$v"
}

# _vg_int <value> — rc 0 for a non-negative integer.
_vg_int() { [[ "${1:-}" =~ ^[0-9]{1,9}$ ]]; }

# _vg_safe <path> — rc 0 for a repo-relative path that is safe as one argv item.
_vg_safe() {
  local p="${1:-}"
  case "$p" in ''|-*|/*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "/$p/" in */../*) return 1 ;; esac
  return 0
}

# _vg_add <entry> — add the entry (a path or a glob) to _VG_OUT, through the filters.
_vg_add() {
  local e="$1" f
  _vg_safe "$e" || return 0
  case "$e" in
    *'*'*|*'?'*|*'['*)
      for f in "${!_VG_TREE[@]}"; do
        # shellcheck disable=SC2254 # the entry is a glob on purpose
        case "$f" in $e) _vg_keep "$f" ;; esac
      done ;;
    *) _vg_keep "$e" ;;
  esac
}
_vg_keep() {
  _vg_safe "$1" || return 0
  case "$1" in e2e/*|*/e2e/*) return 0 ;; esac
  [ -n "${_VG_TREE[$1]:-}" ] || return 0
  _VG_OUT["$1"]=1
}

vg_list() {
  local repo="${1:-.}" head="${2:-HEAD}" srcs src file key txt line max n f t
  local -A _VG_TREE=() _VG_OUT=()
  git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null \
    || { echo "UNREADABLE: head does not resolve: $head" >&2; return 3; }
  while IFS= read -r -d '' f; do _VG_TREE["$f"]=1; done \
    < <(git -C "$repo" ls-tree -r -z --name-only "$head" 2>/dev/null)
  srcs=$(_vg_knob VERIFY_GUARD_SOURCES)
  IFS=, read -r -a src <<< "$srcs"
  for t in ${src[@]+"${src[@]}"}; do
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || continue
    file="${t%%#*}"; key=""
    [ "$file" != "$t" ] && key="${t#*#}"
    _vg_safe "$file" || { echo "UNREADABLE: bad source name in VERIFY_GUARD_SOURCES" >&2; return 3; }
    txt=$(git -C "$repo" show "$head:$file" 2>/dev/null) || continue
    if [ -z "$key" ]; then
      while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in ''|'#'*) continue ;; esac
        _vg_add "$line"
      done <<< "$txt"
      continue
    fi
    [[ "$key" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "UNREADABLE: bad key in VERIFY_GUARD_SOURCES" >&2; return 3; }
    command -v jq >/dev/null 2>&1 || { echo "UNREADABLE: no jq to read $file" >&2; return 3; }
    printf '%s' "$txt" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || { echo "UNREADABLE: $file is not a JSON object" >&2; return 3; }
    printf '%s' "$txt" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1 || continue
    printf '%s' "$txt" | jq -e --arg k "$key" '.[$k] | type == "array" and all(type == "string")' >/dev/null 2>&1 \
      || { echo "UNREADABLE: $file $key is not an array of strings" >&2; return 3; }
    # One JSON string per line, so a value with a newline stays one (rejected) entry.
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | jq -r '.' 2>/dev/null) || continue
      _vg_add "$line"
    done < <(printf '%s' "$txt" | jq -c --arg k "$key" '.[$k][]' 2>/dev/null)
  done
  for f in "${!_VG_TREE[@]}"; do
    case "$f" in tests/static-guards/*) _vg_keep "$f" ;; esac
  done
  max=$(_vg_knob VERIFY_GUARD_MAX)
  n=${#_VG_OUT[@]}
  if _vg_int "$max" && [ "$n" -gt "$max" ]; then
    echo "OVER-CAP: $n guard paths > VERIFY_GUARD_MAX $max" >&2
    return 2
  fi
  [ "$n" = 0 ] && return 0
  printf '%s\n' "${!_VG_OUT[@]}" | LC_ALL=C sort -u
  return 0
}

vg_suite_guards() {
  local tmp rc out
  VG_GUARDS=(); VG_WHY=""
  tmp=$(mktemp) || { VG_WHY="guard list unreadable: no temp file"; return 2; }
  out=$(vg_list "${1:-.}" "${2:-HEAD}" 2> "$tmp"); rc=$?
  case "$rc" in
    0) [ -n "$out" ] && mapfile -t VG_GUARDS <<< "$out" ;;
    2) VG_WHY="guard list over the cap: $(sed -n 's/^OVER-CAP: //p' "$tmp" | head -1)" ;;
    *) VG_WHY="guard list unreadable: $(sed -n 's/^UNREADABLE: //p' "$tmp" | head -1)" ;;
  esac
  rm -f "$tmp"
  [ "$rc" = 0 ] && return 0
  [ "$VG_WHY" = "guard list unreadable: " ] && VG_WHY="guard list unreadable: rc $rc"
  return 2
}
