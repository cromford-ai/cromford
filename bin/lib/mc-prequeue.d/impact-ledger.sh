#!/bin/bash
# bin/lib/mc-prequeue.d/impact-ledger.sh — THE HUB ASKS THE PRE-QUEUE GATE TO
# READ THE SUITE LEDGER INSTEAD OF RUNNING THE IMPACT SELECTION (BH-9178).
# Sourced by bin/lib/mc-prequeue.sh's hook loop, never executed; no side
# effect at source time.
#
# pq_impact_args prints `-f impact=ledger`, or nothing. It prints it when the
# knob MC_PREQUEUE_IMPACT_LEDGER is not 0 AND MC_H carries
# bin/prequeue-ledger.sh, so a hub that has not synced the script keeps
# today's argv. The workflow then runs bin/prequeue-ledger.sh after the
# invariants and runs no impact suite. 0 = the gate runs the suites, as before
# BH-9178. pq_dispatch (empty suites only) and pq_group_flush word-split the
# output into the gh argv.
pq_impact_args() {
  local v
  [ -n "${MC_H:-}" ] && [ -r "$MC_H/bin/prequeue-ledger.sh" ] || return 0
  # Row lane.merge-conductor[.<project>].mc_prequeue_impact_ledger; 1 is the
  # code fallback when no row or registry answers.
  v=$(pq_knob MC_PREQUEUE_IMPACT_LEDGER)
  [ "${v:-1}" = 0 ] || printf '%s %s\n' -f impact=ledger
  return 0
}
