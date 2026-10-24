#!/bin/bash
# bin/lib/ph-pr-record.sh — bin/pipeline-health.sh's per-PR reads from the
# fleet's own PR record before GitHub. Sourced, never executed. Defines
# functions only.
#
# The read rule is pr_record_get's (bin/lib/pr-record.sh), with its helpers
# and its knob, but GitHub is never called here: on a miss the caller runs
# its own old GitHub read, so a miss is exactly the lane's old behavior.
#
#   ph_prr_read <owner/repo> <number> <field...>
#       rc 0  the record row (JSON) on stdout: every requested field that a
#             GitHub read fills is set, and age_s <= PR_RECORD_MAX_AGE_S.
#       rc 1  a miss: nothing on stdout, one PRR_MISS line (ph_prr_miss).
#             no-row      the record has no row for the PR
#             stale       age_s > PR_RECORD_MAX_AGE_S, age_s missing, or the
#                         knob is 0 (then no request is made at all)
#             no-field    a requested GitHub-filled field is null
#             unreadable  _jobs_req is not defined, the GET failed, or the
#                         answer has no "row" object
#       rc 2  bad args or a field name the record does not have: no request,
#             no line.
#
#   ph_prr_miss <owner/repo> <number> <why> [field]
#       Appends one line to logs/pipeline-health.log, best effort:
#         <UTC> PRR_MISS <owner/repo>#<n> why=<why>[ field=<field>]
#       Count the misses: grep -c ' PRR_MISS ' logs/pipeline-health.log
#
#   ph_prr_writeback <owner/repo> <number> <pulls-json-file>
#       After a fallback GitHub read: one pr_record_put (source github) of
#       what the read returned. Only when _jobs_req is defined and the read
#       maps to a non-empty object. Prints nothing, always rc 0.
#
# The knob is PR_RECORD_MAX_AGE_S (catalog/lanes.d/_lib.pr-record.json, read
# by _prr_max_age). This lib never loads the jobs client and never calls gh.
# The root is ${HARNESS:-${H:-}}; with no root the PRR_MISS line is skipped.
[ -n "${_PHPRR_LOADED:-}" ] && return 0
_PHPRR_LIBDIR="${BASH_SOURCE[0]%/*}"
[ -r "$_PHPRR_LIBDIR/pr-record.sh" ] || return 0
# shellcheck source=bin/lib/pr-record.sh
. "$_PHPRR_LIBDIR/pr-record.sh" || return 0
_PHPRR_LOADED=1

ph_prr_miss() {
  local root="${HARNESS:-${H:-}}" extra=""
  [ -n "${4:-}" ] && extra=" field=$4"
  [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s PRR_MISS %s#%s why=%s%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${1:-}" "${2:-}" "${3:-}" "$extra" \
    >> "$root/logs/pipeline-health.log" 2>/dev/null || true
  return 0
}

ph_prr_read() {
  local repo="${1:-}" n="${2:-}" f out row age max
  _prr_args_ok "$repo" "$n" || return 2
  shift 2
  [ "$#" -gt 0 ] || return 2
  for f in "$@"; do
    case " $_PRR_FIELDS " in *" $f "*) ;; *) return 2 ;; esac
  done
  max=$(_prr_max_age)
  if [ "$max" = 0 ]; then ph_prr_miss "$repo" "$n" stale; return 1; fi
  if ! command -v _jobs_req >/dev/null 2>&1 \
     || ! out=$(_jobs_req GET "/api/pr-records?repo=$(_prr_lower "$repo")&number=$n" 2>/dev/null) \
     || ! jq -e 'type == "object" and has("row") and ((.row | type) == "object" or .row == null)' <<<"$out" >/dev/null 2>&1; then
    ph_prr_miss "$repo" "$n" unreadable; return 1
  fi
  row=$(jq -c '.row' <<<"$out")
  if [ "$row" = null ]; then ph_prr_miss "$repo" "$n" no-row; return 1; fi
  for f in "$@"; do
    case " $_PRR_GH_FIELDS " in *" $f "*) ;; *) continue ;; esac
    if jq -e --arg f "$f" '.[$f] == null' <<<"$row" >/dev/null 2>&1; then
      ph_prr_miss "$repo" "$n" no-field "$f"; return 1
    fi
  done
  age=$(jq -r '.age_s // empty' <<<"$out")
  if ! [[ "$age" =~ ^-?[0-9]+$ ]] || [ "$age" -gt "$max" ]; then ph_prr_miss "$repo" "$n" stale; return 1; fi
  printf '%s\n' "$row"
}

ph_prr_writeback() {
  local repo="${1:-}" n="${2:-}" file="${3:-}" mapped
  command -v _jobs_req >/dev/null 2>&1 || return 0
  [ -r "$file" ] || return 0
  mapped=$(_prr_map < "$file")
  [ -n "$mapped" ] && [ "$mapped" != "{}" ] || return 0
  pr_record_put "$repo" "$n" github "$mapped" >/dev/null 2>&1 || true
  return 0
}
