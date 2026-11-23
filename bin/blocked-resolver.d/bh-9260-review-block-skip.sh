# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9260-review-block-skip.sh - A RELEASED
# REVIEW-BLOCK PARK IS NOT RECOVERED FROM ITS HAND-OFF (BH-9260). Sourced by
# bin/blocked-resolver.sh (the BH-7450 fragment block); defines functions only.
#
# A review-block park (bin/lib/mc/review-block-park.sh) lives only while its
# conductor row is parked. A row that moved on had its BLOCK cleared, so
# br_from_conductor must not offer it again from the hand-off record or the
# hand-off log line that outlive the park.
# Tests: tests/br-review-block.bh-9260-test.sh.

# br_rbp_skip <reason> <key> — rc 0 when the hand-off is a review-block park
# (by the logged reason or by the hand-off record's reason); rc 1 otherwise.
br_rbp_skip() {
  case "$1" in review-block*) return 0 ;; esac
  command -v mc_handoff_file >/dev/null 2>&1 || return 1
  case "$(cut -f3 "$(mc_handoff_file "$2")" 2>/dev/null)" in review-block*) return 0 ;; esac
  return 1
}
