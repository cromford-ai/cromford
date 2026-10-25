#!/bin/bash
# bin/lib/pr-owner/prr.sh — bin/pr-owner-sweep.sh's per-PR reads from the
# fleet's own PR record (pr_records, BH-8067) before GitHub. Sourced, never
# executed. Defines functions only.
#
# The read rule is pr_record_get's (bin/lib/pr-record.sh), with its helpers
# and its knob, but GitHub is never called here: on a miss the caller runs its
# own old GitHub read, with its own status handling, so a miss is exactly the
# lane's old behavior (the bin/lib/ph-pr-record.sh shape, BH-8268).
#
#   po_prr_read <owner/repo> <number> <field...>
#       rc 0  the record row (JSON) on stdout: every requested field that a
#             GitHub read fills is set, and age_s <= PR_RECORD_MAX_AGE_S.
#       rc 1  a miss: nothing on stdout, one PRR_MISS line (po_prr_miss).
#             no-row      the record has no row for the PR
#             stale       age_s > PR_RECORD_MAX_AGE_S, age_s missing, or the
#                         knob is 0 (then no request is made at all)
#             no-field    a requested GitHub-filled field is null
#             unreadable  _jobs_req is not defined, the GET failed, or the
#                         answer has no "row" object
#       rc 2  bad args or a field name the record does not have: no request,
#             no line.
#
#   po_prr_miss <owner/repo> <number|list> <why> [field]
#       One line through the sweep's `say` (logs/pr-owner-sweep.log), else
#       stderr:  PRR_MISS <owner/repo>#<n> why=<why>[ field=<field>]
#       Count the misses: grep -c ' PRR_MISS ' logs/pr-owner-sweep.log
#
#   po_prr_writeback <owner/repo> <number> <pulls-json>
#       After a fallback pulls/N read: one pr_record_put (source github) of
#       what the read returned. Only when _jobs_req is defined, PO_DRY is not
#       1 and the read maps to a non-empty object. Prints nothing, rc 0.
#
# The knob is PR_RECORD_MAX_AGE_S (catalog/lanes.d/_lib.pr-record.json, read
# by _prr_max_age). This lib never loads the jobs client and never calls gh.
# Without bin/lib/pr-record.sh it defines nothing, and the callers keep their
# old read (`command -v po_prr_read` is the switch).
[ -n "${_PO_PRR_LOADED:-}" ] && return 0
_PO_PRR_LIBDIR="${BASH_SOURCE[0]%/*}"
[ -r "$_PO_PRR_LIBDIR/../pr-record.sh" ] || return 0
# shellcheck source=bin/lib/pr-record.sh
. "$_PO_PRR_LIBDIR/../pr-record.sh" || return 0
_PO_PRR_LOADED=1

po_prr_miss() {
  local extra=""
  [ -n "${4:-}" ] && extra=" field=$4"
  if declare -F say >/dev/null 2>&1; then
    say "PRR_MISS ${1:-}#${2:-} why=${3:-}$extra"
  else
    printf 'PRR_MISS %s#%s why=%s%s\n' "${1:-}" "${2:-}" "${3:-}" "$extra" >&2
  fi
  return 0
}

po_prr_read() {
  local repo="${1:-}" n="${2:-}" f out row age max
  _prr_args_ok "$repo" "$n" || return 2
  shift 2
  [ "$#" -gt 0 ] || return 2
  for f in "$@"; do
    case " $_PRR_FIELDS " in *" $f "*) ;; *) return 2 ;; esac
  done
  max=$(_prr_max_age)
  if [ "$max" = 0 ]; then po_prr_miss "$repo" "$n" stale; return 1; fi
  if ! command -v _jobs_req >/dev/null 2>&1 \
     || ! out=$(_jobs_req GET "/api/pr-records?repo=$(_prr_lower "$repo")&number=$n" 2>/dev/null </dev/null) \
     || ! jq -e 'type == "object" and has("row") and ((.row | type) == "object" or .row == null)' <<<"$out" >/dev/null 2>&1; then
    po_prr_miss "$repo" "$n" unreadable; return 1
  fi
  row=$(jq -c '.row' <<<"$out")
  if [ "$row" = null ]; then po_prr_miss "$repo" "$n" no-row; return 1; fi
  for f in "$@"; do
    case " $_PRR_GH_FIELDS " in *" $f "*) ;; *) continue ;; esac
    if jq -e --arg f "$f" '.[$f] == null' <<<"$row" >/dev/null 2>&1; then
      po_prr_miss "$repo" "$n" no-field "$f"; return 1
    fi
  done
  age=$(jq -r '.age_s // empty' <<<"$out")
  if ! [[ "$age" =~ ^-?[0-9]+$ ]] || [ "$age" -gt "$max" ]; then po_prr_miss "$repo" "$n" stale; return 1; fi
  printf '%s\n' "$row"
}

po_prr_writeback() {
  local repo="${1:-}" n="${2:-}" pj="${3:-}" mapped
  [ "${PO_DRY:-0}" = 1 ] && return 0
  command -v _jobs_req >/dev/null 2>&1 || return 0
  [ -n "$pj" ] || return 0
  mapped=$(_prr_map <<<"$pj")
  [ -n "$mapped" ] && [ "$mapped" != "{}" ] || return 0
  pr_record_put "$repo" "$n" github "$mapped" >/dev/null 2>&1 </dev/null || true
  return 0
}
