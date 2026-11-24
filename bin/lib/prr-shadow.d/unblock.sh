#!/bin/bash
# bin/lib/prr-shadow.d/unblock.sh — the prr-shadow seam of lane unblock (BH-9926).
# Sourced by prr_seam_load unblock (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 5. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   ub_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   ub_github <file> [args...]  today's GitHub read
#   ub_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.unblock.gh_source) in
# catalog/lanes.d/unblock.knobs.d/.
