# shellcheck shell=bash
# bin/lib/pr-record-readers.sh — BH-10455 (BH-9555.5): a PR's open/closed/merged
# state, read from the PR record (pr_records, bin/lib/pr-record.sh) first.
# Sourced, never executed. Functions only: no set -e, no exit.
#
# Consumers (two):
#   bin/triage-gate.sh, the queue-pending PR-state vector (prrd_pr_state_var).
#   bin/lib/triage-state.d/bh-9555-5-pr-record.sh, the _ts_pr_record_ref seam
#   that _ts_fetch_refs calls before its issues/<n> read (prrd_fresh_state).
#
#   prrd_on
#       rc 0 when the knob PR_RECORD_READERS is on. The knob is the settings
#       row lib.pr-record.pr_record_readers (catalog/lanes.d/
#       _lib.pr-record.knobs.d/PR_RECORD_READERS.json), read through lane_knob
#       (libs scope) when the caller has it, else the environment, else 1.
#       0 is off. Every other value is on.
#
#   prrd_fresh_state <owner/repo> <n>
#       rc 0 and open|closed|merged on stdout when ALL of these hold:
#         prrd_on;
#         pr_record_peek returns a row (ONE jobs GET, never a GitHub call);
#         pr_record_max_age (PR_RECORD_MAX_AGE_S) is above 0;
#         age_s is an integer and 0 <= age_s <= that max;
#         .state is exactly open, closed or merged.
#       Else rc 1 and nothing on stdout. Writes nothing. With the knob off it
#       makes no jobs GET at all.
#
#   prrd_pr_state_var <outvar> <owner/repo> <n>
#       A fresh record: <outvar> = the word, rc 0, no GitHub call. Else
#       gh_rest_pr_state_var <outvar> <owner/repo> <n> exactly as before, and
#       its rc. Never both, never two GitHub calls.
#
# Why pr_record_peek and not pr_record_get: pr_record_get reads GitHub itself
# on a miss. These readers keep the caller's own GitHub read on a miss, so a
# miss costs the same one read as before this lib, and triage-state's fetch
# cap still counts it.
[ -n "${_PRRD_LOADED:-}" ] && return 0
_PRRD_LOADED=1
_PRRD_DIR="$(dirname "${BASH_SOURCE[0]}")"
_PRRD_DEFAULT_ON=1   # fallback only: the knob is PR_RECORD_READERS in catalog/lanes.d/_lib.pr-record.knobs.d/

prrd_on() {
  local v="" _LG_KIND=libs
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob pr-record PR_RECORD_READERS 2>/dev/null); fi
  [ -n "$v" ] || v="${PR_RECORD_READERS:-}"
  [ -n "$v" ] || v=$_PRRD_DEFAULT_ON
  [ "$v" != 0 ]
}

prrd_fresh_state() {
  local repo="${1:-}" n="${2:-}" row max age st
  prrd_on || return 1
  if ! command -v pr_record_peek >/dev/null 2>&1; then
    # shellcheck source=bin/lib/pr-record.sh
    [ -r "$_PRRD_DIR/pr-record.sh" ] && . "$_PRRD_DIR/pr-record.sh" 2>/dev/null
    command -v pr_record_peek >/dev/null 2>&1 || return 1
  fi
  row=$(pr_record_peek "$repo" "$n" 2>/dev/null) || return 1
  max=$(pr_record_max_age 2>/dev/null)
  [[ "$max" =~ ^[0-9]{1,9}$ ]] && [ "$max" -gt 0 ] || return 1
  age=$(jq -r 'if (.age_s | type) == "number" and .age_s == (.age_s | floor) then .age_s else "" end' <<<"$row" 2>/dev/null)
  [[ "$age" =~ ^[0-9]{1,12}$ ]] && [ "$age" -le "$max" ] || return 1
  st=$(jq -r 'if (.state | type) == "string" then .state else "" end' <<<"$row" 2>/dev/null)
  case "$st" in open|closed|merged) printf '%s\n' "$st"; return 0 ;; esac
  return 1
}

prrd_pr_state_var() {
  local _prrd_out="${1:-}" _prrd_st
  [[ "$_prrd_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 75
  if _prrd_st=$(prrd_fresh_state "${2:-}" "${3:-}"); then
    printf -v "$_prrd_out" '%s' "$_prrd_st"
    return 0
  fi
  gh_rest_pr_state_var "$@"
}
