#!/bin/bash
# bin/lib/prr-shadow.d/blocked-resolver.sh — the prr-shadow seam of lane blocked-resolver (BH-9926).
# Sourced by prr_seam_load blocked-resolver (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 5. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   br_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   br_github <file> [args...]  today's GitHub read
#   br_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.blocked-resolver.gh_source) in
# catalog/lanes.d/blocked-resolver.knobs.d/.
