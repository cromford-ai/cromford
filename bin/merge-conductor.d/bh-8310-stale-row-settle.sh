# shellcheck shell=bash
# bin/merge-conductor.d/bh-8310-stale-row-settle.sh - A READY OR WAIT_CI ROW
# OF A PR MEMO'D MERGED OR CLOSED SETTLES (BH-8310). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block); no side effect at
# source time.
#
# mc_offlist_settle_tick <slug> <open-nums> — tick_project calls it after the
# closed-unmerged settle loop. The closed probe memos a merge and writes no
# row, and that memo takes the PR out of every later probe, so its row stayed
# READY for good. This moves such rows to MERGED or CLOSED through
# mc_settle_offlist_rows (bin/lib/mc/settle.sh) in apply mode. No lib: no-op.
# Always rc 0.
mc_offlist_settle_tick() {
  declare -F mc_settle_offlist_rows >/dev/null || return 0
  mc_settle_offlist_rows "$1" "$2" apply >/dev/null
  return 0
}
