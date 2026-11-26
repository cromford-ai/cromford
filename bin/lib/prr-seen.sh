# shellcheck shell=bash
# bin/lib/prr-seen.sh — BH-9937 (BH-9926 wave 5): the per-PR wake gate. A lane
# in step `record` (bin/lib/prr-shadow.sh) stops reading a PR that had no wake
# since its last read. Sourced, never executed. Defines functions only: no
# `set -e`, no `exit`.
#
#   prr_seen_due <lane-id> <owner/repo> <number> <head-sha>
#       rc 0 = read the PR now, rc 1 = skip it (quiet). One word on stdout.
#       First match wins:
#         1. a bad argument, no root, or a lane id that is not
#            ^[a-z0-9][a-z0-9-]*$                          rc 0 no-state
#         2. no row for <number>, or a malformed row        rc 0 no-state
#         3. the row's head is not <head-sha> (lowercase)   rc 0 head
#         4. wb_due <repo> pr - <mark> 0 <back> <number>    rc 0 its word
#         5. wb_due <repo> checks - <mark> 0 <back> <head>  rc 0 its word
#            (CI, status and lead-verdict events wake as kind `checks` keyed
#            on the head sha, worker/jobs/src/lib/core.js wakeOf)
#         6. else                                           rc 1 quiet
#       <back> is the knob PRR_SEEN_BACKSTOP_S. wb_due reads 1..1799 as 1800
#       and 0 as off ("always read"). Its words: off, backstop, no-feed,
#       no-state, wake:pr:<n>, wake:checks:<head>.
#
#   prr_seen_mark <lane-id> <owner/repo> <number> <head-sha> <epoch>
#       Writes the row for <number>: <epoch> is the time the tick STARTED its
#       reads, so a wake that lands during the read wakes the next tick. Call
#       it only AFTER every read of the PR answered. The whole file is read, the
#       row replaced, and the file written tmp + mv under `flock -n` on
#       <file>.lock. A held lock writes nothing and is rc 0: one extra read
#       next tick, never a wrong skip. rc 1 on a bad argument.
#
#   prr_seen_keep <lane-id> <owner/repo> [number...]
#       Rewrites the file with only the rows of the given open PR numbers.
#       The RETENTION rule: a lane calls it once per repo per tick after a
#       complete open list, so the file never holds more rows than the repo
#       has open PRs. Same lock rule as prr_seen_mark.
#
#   prr_seen_now
#       The gate's clock, wb_due's (_wb_now): WAKE_BACKSTOP_NOW under
#       HARNESS_TEST_SANDBOX=1, else the box clock.
#
# STATE (class cache, catalog/state-paths.d/9937-prr-seen.json):
#   <root>/state/prr-seen/<lane-id>/<owner>_<repo>.tsv, rows
#   <number>\t<epoch>\t<head40 lowercase>. It only decides WHETHER to read; no
#   answer ever comes from it. Losing it, or racing on it, costs reads.
#
# The knob PRR_SEEN_BACKSTOP_S (catalog/lanes.d/_lib.prr-seen.json, settings
# row lib.prr-seen.prr_seen_backstop_s) is resolved once, the
# bin/lib/wake-backstop.sh way: lib_env_apply in a SUBSHELL, so a fail-closed
# exit there never stops the lane that sourced this file.
# The root is ${HARNESS:-${H:-}} and nothing else.
if [ -n "${PRR_SEEN_LIB:-}" ]; then return 0 2>/dev/null; fi
PRR_SEEN_LIB=1
_PRR_SEEN_DIR="${BASH_SOURCE[0]%/*}"
# fallback only: the knob is PRR_SEEN_BACKSTOP_S in catalog/lanes.d/_lib.prr-seen.json
_PRR_SEEN_DEFAULT_BACKSTOP_S=1800

if [ "$(type -t wb_due)" != function ]; then
  # shellcheck source=bin/lib/wake-backstop.sh
  . "$_PRR_SEEN_DIR/wake-backstop.sh" 2>/dev/null
fi

_PRR_SEEN_KV=$(
  exec 3>&1
  _PRR_SEEN_R=$(cd "$_PRR_SEEN_DIR/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_PRR_SEEN_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_PRR_SEEN_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_PRR_SEEN_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'printf "%s\n" "${PRR_SEEN_BACKSTOP_S:-}" >&3' EXIT
  lib_env_apply prr-seen >/dev/null 2>&1)
_PRR_SEEN_KV="${_PRR_SEEN_KV%%$'\n'*}"
if [ -n "$_PRR_SEEN_KV" ]; then PRR_SEEN_BACKSTOP_S="$_PRR_SEEN_KV"; fi
unset _PRR_SEEN_KV

prr_seen_now() {
  if [ "$(type -t _wb_now)" = function ]; then _wb_now; else date +%s; fi
}

# _prr_seen_back — the knob as digits; anything else is the documented fallback.
_prr_seen_back() {
  case "${PRR_SEEN_BACKSTOP_S:-}" in
    ''|*[!0-9]*) printf '%s' "$_PRR_SEEN_DEFAULT_BACKSTOP_S" ;;
    *) printf '%s' "$((10#$PRR_SEEN_BACKSTOP_S))" ;;
  esac
}

# _prr_seen_file <lane-id> <owner/repo> — the state file path; rc 1 on a bad
# argument or no root.
_prr_seen_file() {
  local lane="${1:-}" slug="${2:-}" root="${HARNESS:-${H:-}}" s
  [ -n "$root" ] || return 1
  [[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  s="${slug//\//_}"
  printf '%s/state/prr-seen/%s/%s.tsv' "$root" "$lane" "$s"
}

_prr_seen_n_ok() { [[ "${1:-}" =~ ^[1-9][0-9]{0,9}$ ]]; }
_prr_seen_sha() { # prints the lowercase sha, rc 1 when it is not 40 hex
  [[ "${1:-}" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
  printf '%s' "${1,,}"
}

prr_seen_due() {
  local lane="${1:-}" slug="${2:-}" n="${3:-}" head f row rn re rh back w
  f=$(_prr_seen_file "$lane" "$slug") || { echo no-state; return 0; }
  _prr_seen_n_ok "$n" || { echo no-state; return 0; }
  head=$(_prr_seen_sha "${4:-}") || { echo no-state; return 0; }
  [ -r "$f" ] || { echo no-state; return 0; }
  row=$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$f" 2>/dev/null)
  IFS=$'\t' read -r rn re rh <<<"$row"
  [ "$rn" = "$n" ] && [[ "$re" =~ ^[0-9]{1,12}$ ]] || { echo no-state; return 0; }
  rh=$(_prr_seen_sha "$rh") || { echo no-state; return 0; }
  [ "$rh" = "$head" ] || { echo head; return 0; }
  [ "$(type -t wb_due)" = function ] || { echo no-feed; return 0; }
  back=$(_prr_seen_back)
  w=$(wb_due "$slug" pr - "$re" 0 "$back" "$n") && { echo "$w"; return 0; }
  w=$(wb_due "$slug" checks - "$re" 0 "$back" "$head") && { echo "$w"; return 0; }
  echo quiet
  return 1
}

# _prr_seen_write <file> <awk-program> [awk -v args...] — the locked rewrite:
# the old rows through the awk program, then tmp + mv. A held lock writes
# nothing. Always rc 0 once the file path is valid.
_prr_seen_write() {
  local f="$1" prog="$2" fd tmp src; shift 2
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  { exec {fd}>"$f.lock"; } 2>/dev/null || return 0
  if ! flock -n "$fd"; then exec {fd}>&-; return 0; fi
  tmp="$f.tmp.$$"; src="$f"; [ -e "$f" ] || src=/dev/null
  awk -F'\t' -v OFS='\t' "$@" "$prog" "$src" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  exec {fd}>&-
  return 0
}

prr_seen_mark() {
  local lane="${1:-}" slug="${2:-}" n="${3:-}" head ep="${5:-}" f
  f=$(_prr_seen_file "$lane" "$slug") || return 1
  _prr_seen_n_ok "$n" || return 1
  head=$(_prr_seen_sha "${4:-}") || return 1
  [[ "$ep" =~ ^[0-9]{1,12}$ ]] || return 1
  # shellcheck disable=SC2016 # awk program, not shell
  _prr_seen_write "$f" '$1 != n && NF >= 3 { print } END { print n, e, h }' \
    -v n="$n" -v e="$((10#$ep))" -v h="$head"
}

prr_seen_keep() {
  local lane="${1:-}" slug="${2:-}" f keep=" " k; shift 2 2>/dev/null || set --
  f=$(_prr_seen_file "$lane" "$slug") || return 1
  for k in "$@"; do _prr_seen_n_ok "$k" && keep="$keep$k "; done
  [ -e "$f" ] || return 0
  # shellcheck disable=SC2016 # awk program, not shell
  _prr_seen_write "$f" 'index(k, " " $1 " ") > 0 && NF >= 3 { print }' -v k="$keep"
}
