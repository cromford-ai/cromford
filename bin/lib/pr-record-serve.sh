#!/bin/bash
# bin/lib/pr-record-serve.sh — BH-8457: the merge-state read of an open-list
# row, answered from the PR record (bin/lib/pr-record.sh, BH-8067) instead of
# one GitHub `pulls/{n}` GET per row per tick. Sourced, never executed.
# bin/lib/gh-pr-list.sh calls it when the lane exports HPL_PR_RECORD=1; only
# bin/merge-conductor.sh does.
#
#   prr_serve_state <owner/repo> <number> <list-head> <outfile>
#       rc 0: <outfile> holds {head:{sha}, mergeable_state, mergeable}, built
#       from the record with no GitHub call. rc 1: a miss, nothing written; the
#       caller reads as before. ONE jobs GET (pr_record_peek), and none when the
#       knob is 0 or the list head is not a 40-hex sha. It serves only when ALL
#       of these hold:
#         the row is this repo's and this number's, state "open";
#         age_s (the worker's now minus the record's last write) is 0..knob;
#         head_sha, lower-cased, is the list head, lower-cased;
#         mergeable_state is one of the words GitHub computes (a base push or
#         GitHub's own "unknown" stores NULL, BH-8151: a miss).
#       mergeable is false for dirty and true for every other served state.
#       Each call appends `RSERVED <n>` or `RMISS <n>` to $PRS_COUNT_FILE when
#       it is set; the conductor logs them as `<slug> PR-RECORD served= miss=`.
#
#   prr_serve_note <owner/repo> <number> <body-file>
#       After a LIVE pulls/{n} read: the fields a GitHub read fills, written
#       into the record (source github), so the next tick is served. Always
#       rc 0. A failed put is one logs/pr-record.log line:
#         <UTC> serve-note <repo>#<n> put=failed
#
#   prr_serve_max_age
#       The resolved PR_RECORD_SERVE_MAX_AGE_S as a non-negative integer.
#
# The knob PR_RECORD_SERVE_MAX_AGE_S (catalog/lanes.d/_lib.pr-record.knobs.d/)
# is read like pr-record.sh's own: lane_knob when the caller has it, else the
# environment; not a non-negative integer = 120 plus one pr-record.log line.
[ -n "${_PRRS_LOADED:-}" ] && return 0
_PRRS_LOADED=1
# shellcheck source=bin/lib/pr-record.sh
command -v pr_record_peek >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/pr-record.sh" 2>/dev/null
_PRRS_DEFAULT_MAX_AGE_S=120   # fallback only: the knob is PR_RECORD_SERVE_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRRS_STATES='["clean","dirty","blocked","unstable","has_hooks","behind","draft"]'

prr_serve_max_age() {
  command -v _prr_knob >/dev/null 2>&1 || { printf '%s' "$_PRRS_DEFAULT_MAX_AGE_S"; return 0; }
  _prr_knob PR_RECORD_SERVE_MAX_AGE_S "$_PRRS_DEFAULT_MAX_AGE_S"
}

_prrs_count() { [ -n "${PRS_COUNT_FILE:-}" ] && printf '%s %s\n' "$1" "$2" >> "$PRS_COUNT_FILE" 2>/dev/null; return 0; }

prr_serve_state() {
  local slug="${1:-}" n="${2:-}" head out="${4:-}" max row
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  max=$(prr_serve_max_age)
  if [ -n "$out" ] && [ "$max" -gt 0 ] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
     && command -v pr_record_peek >/dev/null 2>&1 && row=$(pr_record_peek "$slug" "$n" 2>/dev/null) \
     && jq -e --arg r "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" --argjson n "$n" --arg h "$head" \
          --argjson max "$max" --argjson ok "$_PRRS_STATES" '
          ((.repo // "") | ascii_downcase) == $r and .number == $n and .state == "open"
          and (.age_s | type) == "number" and .age_s >= 0 and .age_s <= $max
          and ((.head_sha // "") | ascii_downcase) == $h
          and ((.mergeable_state // "") as $m | $ok | index($m) != null)' <<<"$row" >/dev/null 2>&1 \
     && jq -c '{head: {sha: (.head_sha | ascii_downcase)}, mergeable_state,
          mergeable: (.mergeable_state != "dirty")}' <<<"$row" > "$out" 2>/dev/null; then
    _prrs_count RSERVED "$n"
    return 0
  fi
  [ -n "$out" ] && : > "$out" 2>/dev/null
  _prrs_count RMISS "$n"
  return 1
}

prr_serve_note() {
  local mapped
  command -v _prr_map >/dev/null 2>&1 || return 0
  mapped=$(_prr_map < "${3:-/dev/null}")
  [ -n "$mapped" ] && [ "$mapped" != "{}" ] || return 0
  pr_record_put "$1" "$2" github "$mapped" >/dev/null 2>&1 && return 0
  _prr_log "serve-note $(_prr_lower "$1")#$2 put=failed"
  return 0
}
