# shellcheck shell=bash
# bin/merge-conductor.d/bh-9260-review-block-park.sh - THE DRIVER'S CALL SITES
# FOR THE REVIEW-BLOCK PARK (BH-9260). Sourced by bin/merge-conductor.sh (the
# BH-7453 fragment block); no side effect at source time.
#
# The park itself lives in bin/lib/mc/review-block-park.sh, which
# bin/lib/merge-conductor-lib.sh sources (the blocked-resolver reads its brief
# through the same lib). This fragment holds only the three pr_worker hooks, so
# the driver calls one short name at each site. Each reads P KEY SLUG NUM URL
# REC BR HEAD (and the block-gate ones BGOUT REVIEWED MSTATE) from pr_worker's
# scope. With the lib absent, each answers rc 1 and the driver goes on as
# before BH-9260.
# Tests: tests/conductor-review-block-park.bh-9260-test.sh.

# mc_rbp_sticky_release — on the hand-off sticky branch. rc 0 = a review-block
# park whose BLOCK its author cleared was released; the PR classifies on this
# same tick.
mc_rbp_sticky_release() {
  command -v mc_rbp_unpark >/dev/null 2>&1 || return 1
  mc_rbp_unpark "$P" "$KEY" "$SLUG" "$NUM" "$URL" "${REC:--}" "$BR" "$HEAD"
}

# mc_rbp_ready_hold — before the main transition, with STATE in scope. rc 0 = a
# review-block park the resolver released stays parked while its BLOCK stands
# (MC_RBP_WHY holds the reason); READY would only flip it back on the block gate.
mc_rbp_ready_hold() {
  [ "${STATE:-}" = READY ] || return 1
  command -v mc_rbp_hold >/dev/null 2>&1 || return 1
  mc_rbp_hold "$P" "$KEY" "$SLUG" "$NUM" "$URL" "${REC:--}" "$BR" "$HEAD"
}

# mc_rbp_gate_park <ci-hook-rc> — in the block gate, after the refusal. rc 0 =
# the machine review BLOCK bound to this head was parked BLOCKED_HUMAN
# `review-block: <id> …` for the resolver. <ci-hook-rc> is the rc of
# mc_block_ci_step (2, or no hook, = the hook declined the block).
mc_rbp_gate_park() {
  command -v mc_rbp_park >/dev/null 2>&1 || return 1
  mc_rbp_park "$KEY" "$SLUG" "$NUM" "$URL" "${REC:--}" "$HEAD" "${REVIEWED:--}" "${MSTATE:-UNKNOWN}" "$BGOUT" "${1:-2}"
}
