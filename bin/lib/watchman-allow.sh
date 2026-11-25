#!/bin/bash
# bin/lib/watchman-allow.sh — Watchman's path allowlist and its rotation
# register reader (BH-9423, watchman v2). Sourced by
# bin/staff/watchman-collect.sh and bin/staff/watchman-metric.sh. It holds no
# state, makes no request and builds no path from a harness root.
#
#   wm_allow_load
#       Reads WM_PATH_ALLOWLIST (comma-separated patterns) and WM_DUMMY_LINES.
#       A pattern that ends in `/` matches a whole path segment anywhere
#       (`tests/` matches tests/a.env and pkg/tests/x.js, never contests/x).
#       A pattern that starts with `*.` matches the file suffix. Any other
#       pattern is one exact path. A pattern with a character outside
#       [A-Za-z0-9_./*-] is dropped with one warn line on stderr. An empty
#       value, or a value with no valid pattern, is the default list, so the
#       filter never turns off by accident. WM_DUMMY_LINES is 1..50; anything
#       else is one warn line and 5.
#   wm_allowed <repo> <commit> <file>
#       rc 0 = allowlisted; stdout `path` or `dummy`. The path patterns match
#       first. Then the first WM_DUMMY_LINES lines of <file> at <commit> are
#       read with git show: a line that holds `DUMMY VALUES` (any case) is
#       allowlisted. A missing repo, a commit that is gone or a failed read
#       is rc 1 (not allowlisted): an unread file is a hit, never a silenced
#       one. The file content is never printed or logged.
#   wm_allow_split <in> <kept> <repos-root>
#       Copies each location line of <in> ({project, commit, file, ...}, one
#       JSON object per line) that is NOT allowlisted to <kept>, with the repo
#       at <repos-root>/<project>. Sets WM_ALLOW_N_PATH and WM_ALLOW_N_DUMMY to
#       the allowlisted counts of this call.
#   wm_register_read <regdir> <out>
#       Validates each <regdir>/<id>.json of the rotation register and writes
#       one {id, where, owner, due} line per valid file to <out>. Each invalid
#       file is one `<name>.json invalid (<why>)` line on stderr.
#
# Knobs (catalog/lanes.d/_lib.staff-watchman.json, applied by the callers with
# lib_env_apply staff-watchman): WM_PATH_ALLOWLIST (settings row
# lib.staff-watchman.wm_path_allowlist), WM_DUMMY_LINES (settings row
# lib.staff-watchman.wm_dummy_lines).
# Note: docs/notes/2026-11-12-BH-9423-watchman-v2.md.

# The code fallback of the settings row lib.staff-watchman.wm_path_allowlist
# (the ticket's list).
WM_ALLOW_DEFAULT='tests/,__tests__/,e2e/,fixtures/,.harness/specs/,*.md'
# The code fallback of the settings row lib.staff-watchman.wm_dummy_lines.
WM_DUMMY_DEFAULT=5

wm_allow_load() {
  local raw="${WM_PATH_ALLOWLIST:-}" p n="${WM_DUMMY_LINES:-}"
  local -a parts
  WM_ALLOW_PATS=()
  declare -gA WM_ALLOW_SEEN=()
  IFS=',' read -ra parts <<<"$raw"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] || continue
    if [[ $p =~ ^[A-Za-z0-9_./*-]+$ ]]; then
      WM_ALLOW_PATS+=("$p")
    else
      printf 'watchman-allow: warn: WM_PATH_ALLOWLIST pattern %q has a character outside [A-Za-z0-9_./*-]; dropped\n' "$p" >&2
    fi
  done
  if [ "${#WM_ALLOW_PATS[@]}" = 0 ]; then
    [ -n "${raw//[[:space:],]/}" ] && printf 'watchman-allow: warn: WM_PATH_ALLOWLIST has no valid pattern; using the default list\n' >&2
    IFS=',' read -ra WM_ALLOW_PATS <<<"$WM_ALLOW_DEFAULT"
  fi
  if [ -z "$n" ]; then
    WM_ALLOW_LINES=$WM_DUMMY_DEFAULT
  elif [[ $n =~ ^[0-9]+$ ]] && [ "$((10#$n))" -ge 1 ] && [ "$((10#$n))" -le 50 ]; then
    WM_ALLOW_LINES=$((10#$n))
  else
    printf 'watchman-allow: warn: WM_DUMMY_LINES=%q is outside 1..50; using the default %s\n' "$n" "$WM_DUMMY_DEFAULT" >&2
    WM_ALLOW_LINES=$WM_DUMMY_DEFAULT
  fi
  _WM_ALLOW_LOADED=1
  return 0
}

# _wm_allow_check <repo> <commit> <file>: wm_allowed's decision in THIS shell
# (so the per-call cache survives): rc 0 and WM_ALLOW_WHY=path|dummy, or rc 1.
_wm_allow_check() {
  local repo="${1:-}" c="${2:-}" f="${3:-}" p hdr key
  WM_ALLOW_WHY=""
  [ "${_WM_ALLOW_LOADED:-}" = 1 ] || wm_allow_load 2>/dev/null
  [ -n "$f" ] || return 1
  for p in "${WM_ALLOW_PATS[@]}"; do
    case "$p" in
      */)   if [[ $f == "$p"* || $f == *"/$p"* ]]; then WM_ALLOW_WHY=path; return 0; fi ;;
      \*.*) if [[ $f == *"${p#\*}" ]]; then WM_ALLOW_WHY=path; return 0; fi ;;
      *)    if [ "$f" = "$p" ]; then WM_ALLOW_WHY=path; return 0; fi ;;
    esac
  done
  [[ $c =~ ^[0-9a-f]{40}$ ]] && [ -n "$repo" ] && [ -d "$repo" ] || return 1
  key="$repo:$c:$f"
  if [ -n "${WM_ALLOW_SEEN[$key]+x}" ]; then
    [ "${WM_ALLOW_SEEN[$key]}" = dummy ] && { WM_ALLOW_WHY=dummy; return 0; }
    return 1
  fi
  WM_ALLOW_SEEN[$key]=hit
  git -C "$repo" cat-file -e "$c:$f" 2>/dev/null || return 1
  # Capture first, then cut: no consumer closes git's pipe early.
  hdr=$(git -C "$repo" show "$c:$f" 2>/dev/null | tr -d '\000') || true
  hdr=$(sed -n "1,${WM_ALLOW_LINES}p" <<<"$hdr" | tr '[:upper:]' '[:lower:]')
  case "$hdr" in
    *"dummy values"*) WM_ALLOW_SEEN[$key]=dummy; WM_ALLOW_WHY=dummy; return 0 ;;
  esac
  return 1
}

wm_allowed() {
  _wm_allow_check "$@" || return 1
  printf '%s\n' "$WM_ALLOW_WHY"
}

wm_allow_split() {
  local in="${1:-}" out="${2:-}" root="${3:-}" p c f line
  WM_ALLOW_N_PATH=0; WM_ALLOW_N_DUMMY=0
  : > "$out" || return 1
  [ -s "$in" ] || return 0
  while IFS=$'\t' read -r p c f line; do
    [ -n "$line" ] || continue
    if _wm_allow_check "$root/$p" "$c" "$f"; then
      case "$WM_ALLOW_WHY" in
        dummy) WM_ALLOW_N_DUMMY=$((WM_ALLOW_N_DUMMY + 1)) ;;
        *) WM_ALLOW_N_PATH=$((WM_ALLOW_N_PATH + 1)) ;;
      esac
      continue
    fi
    printf '%s\n' "$line" >> "$out"
  done < <(paste -d'\t' <(jq -r '[(.project // ""), (.commit // ""), (.file // "")] | @tsv' "$in" 2>/dev/null) "$in")
  return 0
}

wm_register_read() {
  local d="${1:-}" out="${2:-}" f name why
  : > "$out" || return 1
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .json)
    why=$(jq -r --arg n "$name" '
      def realdate: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        and ((. + "T00:00:00Z" | try (fromdateiso8601 | strftime("%Y-%m-%d")) catch "") as $r | $r == .);
      def printable($max): type == "string" and length >= 1 and length <= $max and (test("[[:cntrl:]]") | not);
      if type != "object" then "not an object"
      elif (.id | type) != "string" or (.id | test("^[a-z][a-z0-9-]{1,47}$") | not) then "id"
      elif .id != $n then "the file name is not <id>.json"
      elif (.where | printable(200) | not) then "where"
      elif (.where | test("[A-Za-z0-9+/=_-]{24,}")) then "where looks like a value; name the file and the variable"
      elif (.owner | printable(100) | not) then "owner"
      elif has("due") and (has("rotated_at") or has("every_days")) then "both due and rotated_at"
      elif has("due") then (if (.due | realdate) then "" else "due" end)
      elif (has("rotated_at") and has("every_days")) | not then "neither due nor rotated_at + every_days"
      elif (.rotated_at | realdate | not) then "rotated_at"
      elif (.every_days | type) != "number" or .every_days != (.every_days | floor) or .every_days < 1 or .every_days > 3650 then "every_days"
      else "" end' "$f" 2>/dev/null) || why="not JSON"
    if [ -n "$why" ]; then printf '%s.json invalid (%s)\n' "$name" "$why" >&2; continue; fi
    jq -c '{id, where, owner, due: (.due // ((.rotated_at + "T00:00:00Z" | fromdateiso8601) + .every_days * 86400 | strftime("%Y-%m-%d")))}' "$f" >> "$out"
  done
  return 0
}
