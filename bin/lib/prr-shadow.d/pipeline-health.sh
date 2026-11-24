#!/bin/bash
# bin/lib/prr-shadow.d/pipeline-health.sh — the prr-shadow seam of lane pipeline-health (BH-9926).
# Sourced by prr_seam_load pipeline-health (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 6. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   ph_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   ph_github <file> [args...]  today's GitHub read
#   ph_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.pipeline-health.gh_source) in
# catalog/lanes.d/pipeline-health.knobs.d/.
