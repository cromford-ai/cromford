#!/bin/bash
# bin/lib/prr-shadow.d/merge-conductor.sh — the prr-shadow seam of lane merge-conductor (BH-9926).
# Sourced by prr_seam_load merge-conductor (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 6. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   mc_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   mc_github <file> [args...]  today's GitHub read
#   mc_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.merge-conductor.gh_source) in
# catalog/lanes.d/merge-conductor.knobs.d/.
