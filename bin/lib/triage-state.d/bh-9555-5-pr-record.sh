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
# THIS IS THE PLACEHOLDER: rc 1 always (a miss), so every ref is read as before.
_ts_pr_record_ref() {
  return 1
}
