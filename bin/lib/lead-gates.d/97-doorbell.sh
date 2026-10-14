#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/97-doorbell.sh — gate 15 of bin/lead-review-enqueue.sh,
# the lead-chain doorbell (BH-4057), ported to the worklist.
#   lg_post_doorbell <slug> <n> <head>   after lr_start claimed the row:
#       lcw_ring lead-review (bin/lib/lead-chain-wake.sh, which
#       bin/lead-review.sh sources) in a subshell, then one log line, `<slug>#<n>
#       @<h12>: lead-review doorbell rung` or `doorbell not rung (rc N); the
#       */15 cron covers it`. The ring is deduped per (PR, head) in the wakes
#       table, and the rerun it causes is bounded by LEAD_REVIEW_RERUN_MAX.
#       flags/lead-chain-wake-off stops it (rc 1). No lcw_ring: one log line.
#       Always rc 0 (fail-open: a lost ring costs one cron tick).
# Sourced by bin/lib/lead-gates.sh, never run.

lg_post_doorbell() {
  local rc=0
  if ! command -v lcw_ring >/dev/null 2>&1; then
    _lgt_log "$1#$2 @${3:0:12}: doorbell not rung (no lcw_ring); the */15 cron covers it"; return 0
  fi
  ( lcw_ring lead-review "$1" "$2" "$3" ) || rc=$?
  if [ "$rc" = 0 ]; then _lgt_log "$1#$2 @${3:0:12}: lead-review doorbell rung"
  else _lgt_log "$1#$2 @${3:0:12}: doorbell not rung (rc $rc); the */15 cron covers it"; fi
  return 0
}
