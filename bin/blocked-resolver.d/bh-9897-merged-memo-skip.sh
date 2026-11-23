# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9897-merged-memo-skip.sh — BH-9897 item 5: the
# conductor discovery skips a row whose PR the closed-watch memo says merged.
#
# WHY. A PR that merged outside the conductor keeps its BLOCKED_HUMAN or
# RED_TWICE row until the conductor's off-list settle moves it to MERGED. In
# that window br_from_conductor counted the row as a candidate and the hand-off
# loop spent a REST read on it. The memo is local and already says merged, so
# the row is skipped before any read.
#
# Call sites, one line each, in br_from_conductor (bin/blocked-resolver.sh):
#   the first row loop, after br_key_in_only, and the hand-off loop, before
#   `rowst=$(mc_row_field ...)`:
#     command -v brmm_merged >/dev/null 2>&1 && brmm_merged "$key" && continue
#   the end of the function:
#     command -v brmm_say >/dev/null 2>&1 && brmm_say
# BR_OPT_OFF=bh-9897-merged-memo-skip does not source this file: every row is
# then a candidate again, as before BH-9897.
#
# The hit count goes to a scratch file, ${TMPDIR:-/tmp}/br-mm.$$, not to a
# variable: br_candidates runs br_from_conductor inside $( ), and in bash $$ in
# that subshell is still the driver's pid. brmm_say reads and removes it.
# Defines functions only; no side effect at source time.

# brmm_merged <slug>#<num> — rc 0 when the closed-watch memo of this PR is a
#   regular readable file whose first tab field is exactly `merged`; rc 1 for
#   no memo, open, closed, gone, an unreadable memo, a directory, or a key
#   that is not <slug>#<num> with a numeric num.
brmm_merged() {
  local key="${1:-}" slug num dir f first rest
  case "$key" in *'#'*) ;; *) return 1 ;; esac
  slug="${key%#*}"; num="${key##*#}"
  [ -n "$slug" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  command -v mc_safe_name >/dev/null 2>&1 || return 1
  dir="${MC_CLOSED_WATCH_DIR:-}"
  if [ -z "$dir" ]; then
    [ -n "${MC_STATE_DIR:-}" ] || return 1
    dir="$MC_STATE_DIR/closed-watch"
  fi
  f="$dir/$(mc_safe_name "$slug")/$num"
  [ -f "$f" ] && [ -r "$f" ] || return 1
  IFS=$'\t' read -r first rest < "$f" 2>/dev/null || [ -n "${first:-}" ] || return 1
  [ "$first" = merged ] || return 1
  printf '%s\n' "$key" >> "${TMPDIR:-/tmp}/br-mm.$$" 2>/dev/null
  return 0
}

# brmm_say — one say line with the number of distinct keys skipped since the
#   last call, then removes the scratch file. A key skipped by both the row
#   loop and the hand-off loop counts once. Says nothing at 0. Always rc 0.
brmm_say() {
  local f="${TMPDIR:-/tmp}/br-mm.$$" n=0
  [ -f "$f" ] && n=$(sort -u "$f" 2>/dev/null | wc -l | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] && say "discovery: $n conductor row(s) skipped, PR memo'd merged (the conductor's off-list settle moves them)"
  rm -f "$f" 2>/dev/null
  return 0
}
