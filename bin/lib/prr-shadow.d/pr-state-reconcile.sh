#!/bin/bash
# bin/lib/prr-shadow.d/pr-state-reconcile.sh — the prr-shadow seam of lane pr-state-reconcile (BH-9926).
# Sourced by prr_seam_load pr-state-reconcile (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 5. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   psr_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   psr_github <file> [args...]  today's GitHub read
#   psr_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.pr-state-reconcile.gh_source) in
# catalog/lanes.d/pr-state-reconcile.knobs.d/.
