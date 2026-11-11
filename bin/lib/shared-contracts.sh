#!/bin/bash
# bin/lib/shared-contracts.sh — a repo's shared contracts: the rules a diff
# must keep when it touches a path of a given kind (a new migration needs a
# tenancy header, a new lane needs a catalog/lanes.d fragment). The repo
# declares them, the primer carries them to the plan, and the plan gate refuses
# a plan that does not list a contract its paths trigger
# (prompts/plan-contract.md §18).
# Sourced, never executed: functions only, no output at source time.
#
# THE FRAGMENT (in the repo, never in the harness): catalog/shared-contracts.d/
# *.tsv, one contract per line, exactly 5 TAB-separated fields:
#   <id> <when> <path-glob> <requires> <enforced-by>
#   id           ^[a-z0-9][a-z0-9-]*$, unique over the dir (C-order first wins)
#   when         new (the path is absent from the repo) | any
#   path-glob    a bash glob over a repo-relative path, `*` crosses `/`
#   requires     what the diff must add, one sentence
#   enforced-by  the check that goes red without it
# `#` comment lines and blank lines are skipped. Any other line that breaks a
# rule is not used and is reported as `BAD: <file>:<line> <why>`.
#
# THE BUILD FILE (sc_write, read by sc_plan_check): line 1 `# repo: <abs path>`,
# then one row per valid contract, 6 TAB fields: the 5 above plus
# `<repo-relative file>:<line>`.
#
# THE FUNCTIONS
#   sc_read <repo>                  rows (6 TAB fields) and BAD: lines, stdout
#   sc_write <repo> <out>           the build file; rc 1 = not written
#   sc_section <repo>               the primer block; sets SC_STATE yes|no|bad
#   sc_triggered <plan> <file>      `<id>\t<path>` per triggered contract, once
#   sc_listed <plan> <id>           rc 0 = the id is under `## Shared contracts`
#   sc_conf [project]               sets SC_ENFORCE (0|1) and SC_CONF_WARN
#   sc_plan_check <plan> <file>     the plan gate (rc 2 = refuse)
#
# THE KNOB (catalog/lanes.d/_lib.shared-contracts.json, id shared-contracts),
# read through lib_env_apply, else the env, else SC_DEFAULT_ENFORCE below.

SC_DEFAULT_ENFORCE=1
SC_DIR_REL="catalog/shared-contracts.d"

# sc_read <repo> — every row of the repo's fragment dir, validated. Valid rows
# print as 6 TAB fields; a bad row prints `BAD: <file>:<line> <why>`.
# rc 1: the repo is not a directory. No fragment dir: no output, rc 0.
sc_read() {
  local repo="${1:-}" f rel
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  [ -d "$repo/$SC_DIR_REL" ] || return 0
  local -a files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(
    find "$repo/$SC_DIR_REL" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null | LC_ALL=C sort)
  [ "${#files[@]}" -gt 0 ] || return 0
  for f in "${files[@]}"; do
    rel="$SC_DIR_REL/${f##*/}"
    tr -d '\r' < "$f" | awk -F'\t' -v rel="$rel" '{ print rel "\t" NR "\t" NF "\t" $0 }'
  done | awk -F'\t' '
    {
      rel = $1; ln = $2; nf = $3
      line = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", line)
      if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
      where = rel ":" ln
      if (nf != 5) { printf "BAD: %s has %d field(s), needs 5 TAB-separated fields\n", where, nf; next }
      id = $4; when = $5; glob = $6; req = $7; enf = $8
      if (id !~ /^[a-z0-9][a-z0-9-]*$/) { printf "BAD: %s id \"%s\" is not ^[a-z0-9][a-z0-9-]*$\n", where, id; next }
      if (when != "new" && when != "any") { printf "BAD: %s when \"%s\" is not new or any\n", where, when; next }
      if (glob == "" || glob ~ /[ \t]/) { printf "BAD: %s path-glob \"%s\" is empty or has whitespace\n", where, glob; next }
      if (req ~ /^[ ]*$/) { printf "BAD: %s requires is empty\n", where; next }
      if (enf ~ /^[ ]*$/) { printf "BAD: %s enforced-by is empty\n", where; next }
      if (id in seen) { printf "BAD: %s id \"%s\" is already declared at %s\n", where, id, seen[id]; next }
      seen[id] = where
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, when, glob, req, enf, where
    }'
  return 0
}

# sc_write <repo> <out> — the build file the plan gate reads. Written through
# a temp file in the same dir and a move. rc 1: no repo, or not written.
sc_write() {
  local repo="${1:-}" out="${2:-}" abs tmp
  [ -n "$out" ] && [ -n "$repo" ] && [ -d "$repo" ] || return 1
  abs=$(cd "$repo" 2>/dev/null && pwd) || return 1
  tmp=$(mktemp "$(dirname "$out")/.sc.XXXXXX" 2>/dev/null) || return 1
  # grep -v exits 1 when there is no row; a repo with no contract is still a
  # file the gate reads (0 declared), so only the write itself can fail here.
  { printf '# repo: %s\n' "$abs"; sc_read "$abs" | { grep -v '^BAD: ' || true; }; } > "$tmp" 2>/dev/null \
    && mv "$tmp" "$out" 2>/dev/null && return 0
  rm -f "$tmp"; return 1
}

# sc_section <repo> — the `--- SHARED CONTRACTS` primer block. SC_STATE: yes
# (at least one valid row), no (no dir, or a dir with no rows), bad (rows, and
# none of them valid). The caller caps the block.
sc_section() {
  local repo="${1:-}" rows n nbad
  SC_STATE=no
  echo "--- SHARED CONTRACTS (source: $SC_DIR_REL/) ---"
  if [ ! -d "$repo/$SC_DIR_REL" ]; then
    echo "ABSENT: no $SC_DIR_REL/ in $repo — this repo declares no shared contracts."
    return 0
  fi
  rows=$(sc_read "$repo")
  n=$(grep -cv '^BAD: ' <<<"$rows"); [ -n "$rows" ] || n=0
  nbad=$(grep -c '^BAD: ' <<<"$rows")
  if [ "$n" -gt 0 ]; then SC_STATE=yes; elif [ "$nbad" -gt 0 ]; then SC_STATE=bad; fi
  if [ "$n" -gt 0 ]; then
    echo "$n contract(s). A contract is triggered when a path your plan touches matches its glob"
    echo "(when=new: and the path does not exist yet). Format: id | when | glob | requires | enforced by | source."
    grep -v '^BAD: ' <<<"$rows" | awk -F'\t' '{ printf "- %s | %s | %s | %s | %s | %s\n", $1, $2, $3, $4, $5, $6 }'
  else
    echo "NONE: $SC_DIR_REL/ in $repo holds no valid contract row."
  fi
  [ "$nbad" -gt 0 ] && grep '^BAD: ' <<<"$rows"
  echo "PLAN: list each contract your planned paths trigger under \`## Shared contracts\`, one line per id with the file that satisfies it; bin/plan-gate.sh refuses a plan that omits one."
  echo "EXECUTE: add each contract the plan's \`## Shared contracts\` lists, in the same diff."
  return 0
}

# _sc_tokens <plan> — the path tokens of the plan, one per line. Skipped, as in
# bin/planned-files.sh: `## Sibling claims` (to the next #/## heading, or a
# deeper heading that is not a ticket key), `## Verify` (to the next #/##
# heading), and a VALIDATE: line. Also skipped: fenced lines. A token is
# `[A-Za-z0-9_@./-]+` with a `/` in it, trailing `.` `,` `:` `;` `)` cut off.
_sc_tokens() {
  tr -d '\r' < "$1" | awk '
    /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    /^#+[ \t]/ {
      t = tolower($0)
      if (t ~ /^##?[ \t]/) {
        skip = (t ~ /^##[ \t]+sibling claims/)
        vskip = (t ~ /^##[ \t]+verify/)
      }
      else if (skip && t !~ /^#+[ \t]+[a-z][a-z0-9]*-[0-9]+/) skip = 0
    }
    /^[ \t]*([-*][ \t]+)?VALIDATE:/ { next }
    !skip && !vskip' \
  | grep -oE '[A-Za-z0-9_@./-]+' | grep '/' | sed -E 's/[.,:;)]+$//' | awk '!seen[$0]++'
}

# _sc_rows <file> — the contract rows of a build file (6 fields), or rc 1 when
# it is not one: unreadable, no `# repo:` line 1, or a row of another shape.
_sc_rows() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 1
  head -1 "$f" | grep -q '^# repo: /' || return 1
  awk -F'\t' 'NR == 1 { next } /^[ \t]*$/ { next } NF != 6 { bad = 1; exit } { print } END { exit bad }' "$f"
}

sc_repo_of() { sed -n '1s/^# repo: //p' "${1:-}" 2>/dev/null; }

# sc_triggered <plan> <file> — `<id>\t<first path>` for each contract the plan
# triggers, in the file's row order. rc 1: the file is not a build file.
sc_triggered() {
  local plan="${1:-}" file="${2:-}" rows repo id when glob _r _e _s tok
  rows=$(_sc_rows "$file") || return 1
  repo=$(sc_repo_of "$file")
  [ -r "$plan" ] || return 0
  local -a toks=()
  while IFS= read -r tok; do [ -n "$tok" ] && toks+=("$tok"); done < <(_sc_tokens "$plan")
  [ "${#toks[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r id when glob _r _e _s; do
    [ -n "$id" ] || continue
    for tok in "${toks[@]}"; do
      # shellcheck disable=SC2053  # the glob is the contract's pattern, on purpose
      [[ "$tok" == $glob ]] || continue
      [ "$when" = new ] && [ -e "$repo/$tok" ] && continue
      printf '%s\t%s\n' "$id" "$tok"; break
    done
  done <<<"$rows"
  return 0
}

# sc_listed <plan> <id> — rc 0 when the id is a whole token (any case; the
# bytes around it are not [A-Za-z0-9_-]) on a non-fenced line under a heading
# whose text starts "Shared contracts", up to the next heading at the same or
# a higher level.
sc_listed() {
  tr -d '\r' < "${1:-/dev/null}" 2>/dev/null | awk -v id="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')" '
    /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    /^#+[ \t]/ {
      match($0, /^#+/); lvl = RLENGTH
      if (open && lvl <= olvl) open = 0
      h = $0; sub(/^#+[ \t]*/, "", h); gsub(/[*_`]/, "", h); h = tolower(h)
      if (!open && h ~ /^shared contracts/) { open = 1; olvl = lvl }
      next
    }
    !open { next }
    {
      l = tolower($0); off = 0
      while ((i = index(substr(l, off + 1), id)) > 0) {
        i += off
        b = (i > 1) ? substr(l, i - 1, 1) : ""
        a = substr(l, i + length(id), 1)
        if (b !~ /[a-z0-9_-]/ && a !~ /[a-z0-9_-]/) { found = 1; exit }
        off = i
      }
    }
    END { exit found ? 0 : 1 }'
}

# sc_conf [project] — SC_ENFORCE from SHARED_CONTRACTS_ENFORCE: lib_env_apply
# in a subshell, then the env, then SC_DEFAULT_ENFORCE. A value that is not
# on/off enforces and sets SC_CONF_WARN.
sc_conf() {
  local p="${1:-${PROJECT:-}}" root e
  root="${HARNESS:-${H:-}}"
  SC_CONF_WARN=""
  e=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply shared-contracts "$p" >/dev/null 2>&1
    printf '%s' "${SHARED_CONTRACTS_ENFORCE:-}"
  ) || e=""
  case "$(printf '%s' "${e:-$SC_DEFAULT_ENFORCE}" | tr 'A-Z' 'a-z')" in
    0|off|false|no) SC_ENFORCE=0 ;;
    1|on|true|yes) SC_ENFORCE=1 ;;
    *) SC_ENFORCE=1; SC_CONF_WARN="SHARED_CONTRACTS_ENFORCE='$e' is not on/off, so it enforces" ;;
  esac
  return 0
}

# sc_plan_check <plan> <file> — one UNTRACED (or NOTE) line per triggered id
# the plan does not list, then `PLAN_CONTRACTS: ok (<t> triggered, <d>
# declared) | unlisted | unread`. rc 2 = refuse. A file it cannot read, or a
# repo path that is gone, is `unread` and never refuses.
sc_plan_check() {
  local plan="${1:-}" file="${2:-}" rows repo trig d t miss="" id path req _w _g _e _s pfx
  if ! rows=$(_sc_rows "$file"); then echo "PLAN_CONTRACTS: unread"; return 0; fi
  repo=$(sc_repo_of "$file")
  [ -d "$repo" ] || { echo "PLAN_CONTRACTS: unread"; return 0; }
  d=$(grep -c . <<<"$rows"); [ -n "$rows" ] || d=0
  trig=$(sc_triggered "$plan" "$file") || { echo "PLAN_CONTRACTS: unread"; return 0; }
  t=0
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    t=$((t+1))
    sc_listed "$plan" "$id" && continue
    req=$(awk -F'\t' -v id="$id" '$1 == id { print $4; exit }' <<<"$rows")
    miss="$miss$id"$'\t'"$req"$'\t'"$path"$'\n'
  done <<<"$trig"
  if [ -z "$miss" ]; then echo "PLAN_CONTRACTS: ok ($t triggered, $d declared)"; return 0; fi
  sc_conf
  [ -n "$SC_CONF_WARN" ] && echo "  NOTE: $SC_CONF_WARN"
  pfx="  UNTRACED: shared contract — "
  [ "$SC_ENFORCE" = 0 ] && pfx="  NOTE: shared contract (SHARED_CONTRACTS_ENFORCE=0) — "
  while IFS=$'\t' read -r id req path; do
    [ -n "$id" ] && echo "${pfx}${id}: ${req} (triggered by ${path}); list it under '## Shared contracts'"
  done <<<"$miss"
  if [ "$SC_ENFORCE" = 0 ]; then echo "PLAN_CONTRACTS: unlisted (not enforced, SHARED_CONTRACTS_ENFORCE=0)"; return 0; fi
  echo "PLAN_CONTRACTS: unlisted"
  return 2
}
