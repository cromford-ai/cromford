#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/12-autopilot-bound.sh — BH-9823: no lead review of a
# head the >12h autopilot already verdicted. One verdict of record per head.
#   lg_gate_autopilot_bound <slug> <pr> <head>:
#     the repo does not require a lead MERGE (lr_required rc 1), AND the newest
#     `source=box` row on THIS exact head (vd_box_word) is MERGE or
#     MERGE-WITH-NOTES                    rc 10 [skip autopilot-bound], once per
#                                         (PR, head) through lgs_skip_once.
#     anything else                       rc 0, today's chain: no box row, a box
#                                         BLOCK, any other box word,
#                                         an unreadable
#                                         or unloaded read, a lead_required repo
#                                         (lr_required rc 0: it merges only on a
#                                         lead MERGE, so the lead must run) or an
#                                         unreadable lead_required row (rc 2).
# THE DEFECT (PR #9811). The conductor consumed the autopilot MERGE and rebound
# the builder APPROVE onto the head. That put the head on the worklist
# (needsReviewRows), gate 10 passed it, and the lead lane bought a second
# review whose BLOCK dequeued the PR. The conductor half of the fix is
# bin/merge-conductor.d/bh-9823-one-verdict.sh.
# The gate runs only for worklist items. An explicit request row (a person's
# bin/lead-verdict.sh request, the resolver's re-review ask, the BH-8890
# lead_required ask) is not gated; the conductor then waits for that lead
# verdict, so the head still gets one verdict of record.
# Cost: one memoised settings read, then one GET /api/verdicts?repo&pr&head
# (the existing route and index) only on a repo that does not require a lead.
# A box BLOCK is NOT bound: a box row never stands (bin/lib/verdicts.sh
# vd_box_word), and the conductor reads a box row only on a HEAD_MOVED row. On a
# READY head the builder APPROVE alone would enqueue it, so the lead review must
# run there: its BLOCK is the row the block gate refuses.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/verdicts.sh
command -v vd_box_word >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../verdicts.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-required.sh
command -v lr_required >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-required.sh" 2>/dev/null || true

lg_gate_autopilot_bound() {
  local slug="$1" n="$2" head w rrc=0
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  command -v lr_required >/dev/null 2>&1 && command -v vd_box_word >/dev/null 2>&1 || return 0
  lr_required "$slug" || rrc=$?
  [ "$rrc" = 1 ] || return 0
  w=$(vd_box_word "$slug" "$n" "$head" 2>/dev/null) || return 0
  case "$w" in MERGE|MERGE-WITH-NOTES) ;; *) return 0 ;; esac
  if command -v lgs_skip_once >/dev/null 2>&1; then
    lgs_skip_once "$slug" "$n" "$head" autopilot-bound "the >12h autopilot verdicted $w on this exact head; that is the review of record (BH-9823)"
  else
    _lgt_log "[skip autopilot-bound] $slug#$n @${head:0:12} the >12h autopilot verdicted $w on this exact head; that is the review of record (BH-9823)"
  fi
  return 10
}
