#!/bin/bash
# bin/lib/prr-shadow.d/wake-loop.sh — the prr-shadow seam of lane wake-loop (BH-9926).
# Sourced by prr_seam_load wake-loop (bin/lib/prr-shadow.sh), never executed.
#
# Empty until BH-9926 wave 6. That wave defines here the three functions
# prr_read takes for this lane's GitHub reads:
#   wl_record <file> [args...]  the read from the PR record; prints a miss word on rc != 0
#   wl_github <file> [args...]  today's GitHub read
#   wl_norm <file>              the compare form: a JSON array keyed on .n
# and registers the knob GH_SOURCE (settings row lane.wake-loop.gh_source) in
# catalog/lanes.d/wake-loop.knobs.d/.
# The pr-lead wake class runs inside this lane, so its reads move under this
# lane id: the step row is keyed by lane id, lane.wake-loop.gh_source.
