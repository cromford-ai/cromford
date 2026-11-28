# shellcheck shell=bash
# bin/lib/triage-state.d/bh-9555-5-pr-record.sh — SOURCED by
# bin/lib/triage-state.sh. The PR-record seam of the BH-9555 contract
# (BH-9594). # owner: BH-9555.5
#
# _ts_pr_record_ref <owner/repo> <n>
#   Called by _ts_fetch_refs before its GitHub read of ref #<n>. rc 0 means
#   "served": the hook has set _TS_PR_REF_ST to OPEN, CLOSED or MERGED, and the
#   caller makes no GitHub read and spends no fetch cap. rc 1 means "miss": the
#   caller reads GitHub as today.
#
# BH-10455: served from a FRESH pr_records row (prrd_fresh_state,
# bin/lib/pr-record-readers.sh: one jobs GET, never a GitHub call). A ref with
# no row (an issue, or a PR the record does not hold), a row older than
# PR_RECORD_MAX_AGE_S, a failed jobs read, or the kill row
# lib.pr-record.pr_record_readers=0 is a miss. No lib (a box mid-sync) is a miss.
_ts_pr_record_ref() {
  local st
  _TS_PR_REF_ST=""
  if ! command -v prrd_fresh_state >/dev/null 2>&1; then
    # shellcheck source=bin/lib/pr-record-readers.sh
    [ -r "$(dirname "${BASH_SOURCE[0]}")/../pr-record-readers.sh" ] \
      && . "$(dirname "${BASH_SOURCE[0]}")/../pr-record-readers.sh" 2>/dev/null
    command -v prrd_fresh_state >/dev/null 2>&1 || return 1
  fi
  st=$(prrd_fresh_state "${1:-}" "${2:-}" 2>/dev/null) || return 1
  case "$st" in
    open) _TS_PR_REF_ST=OPEN ;;
    closed) _TS_PR_REF_ST=CLOSED ;;
    merged) _TS_PR_REF_ST=MERGED ;;
    *) return 1 ;;
  esac
  return 0
}
