#!/bin/bash
# bin/lib/prr-shadow.d/main-red-pr-pair.sh — the prr-shadow seam of lane main-red-pr-pair (BH-9926).
# Sourced by prr_seam_load main-red-pr-pair (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 5. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   mrp_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   mrp_github <file> [args...]  today's GitHub read
#   mrp_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.main-red-pr-pair.gh_source) in
# catalog/lanes.d/main-red-pr-pair.knobs.d/.
