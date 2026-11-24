#!/bin/bash
# bin/lib/prr-shadow.d/dequeue-watch.sh — the prr-shadow seam of lane dequeue-watch (BH-9926).
# Sourced by prr_seam_load dequeue-watch (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 6. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   dqw_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   dqw_github <file> [args...]  today's GitHub read
#   dqw_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.dequeue-watch.gh_source) in
# catalog/lanes.d/dequeue-watch.knobs.d/.
