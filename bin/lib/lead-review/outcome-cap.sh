#!/bin/bash
# shellcheck shell=bash
# module: outcome-cap
# bin/lib/lead-review/outcome-cap.sh — the BH-8338 report side of the outcome
# cap (bin/lib/lead-outcome-cap.sh, BH-6372.3): the capped report body and the
# refusal of a BLOCK with no finding line. Sourced by bin/lead-review.sh through
# bin/lib/lead-review/load.sh, never run. Defines functions only.

# lr_cap_body <agent-out> <finding-line> <verdict> — the agent text of a capped
# report: the cap's one finding line, the agent's text with its VERDICT lines
# demoted (loc_demote), and the capped verdict as the trailing VERDICT line.
lr_cap_body() {
  [ -n "$2" ] && printf '%s\n\n' "$2"
  loc_demote "$1"; printf '\nVERDICT: %s\n' "$3"
}

# lr_block_no_finding <verdict> <report> — rc 0 when the verdict is BLOCK and
# the report has no `- [BLOCK` finding line. The same anchored grep as
# bin/lead-review-land.sh: a BLOCK the land lane cannot brief is not a verdict.
lr_block_no_finding() {
  [ "$1" = BLOCK ] && ! grep -q '^- \[BLOCK' "$2"
}
