#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/75-self-check.sh — gate 7 of bin/lead-review-enqueue.sh,
# the pre-review self-check (BH-5798, header `self`), ported to the worklist.
# It holds a head whose PR body fails a rule of catalog/pr-self-check.tsv that
# is NOT a body-* rule (78-body-lint.sh owns those): Closes on a partial build
# (closes-not-met), evidence bound to an older head (evidence-head), a file
# outside the plan (plan-files), another ticket's test (test-ownership).
#   No such refusal, or the check cannot run (lgsc_run rc 2)  rc 0.
#   A refusal  lgsc_hold (bin/lib/lead-gates-selfcheck.sh): one PR comment per
#       (head, body) naming EVERY refusal, body-* ones too; rc 11 while the
#       hold is younger than PR_SELF_CHECK_MAX_WAIT_MIN, rc 0 past it.
# It runs after 60-risk.sh, so a low-tier sign-off is never held here (the
# enqueue's order: the self check sits after the risk tier). Sourced by
# bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-selfcheck.sh
command -v lgsc_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-selfcheck.sh" 2>/dev/null || true

lg_gate_self_check() {
  local head
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  command -v lgsc_run >/dev/null 2>&1 || return 0
  lgsc_run "$1" "$2" "$head" || return 0
  [ -n "$(lgsc_refusals other)" ] || return 0
  lgsc_hold "$1" "$2" "$head" "$(lgsc_refusals all)"
}
