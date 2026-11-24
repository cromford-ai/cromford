# owner: BH-9786.3
# shellcheck shell=bash
# bin/lib/perf-probe/session-end.sh — the session-end seam of the perf probe
# (sourced by bin/lib/perf-probe.sh). bin/perf-probe.sh calls it when a route
# load answers 401.
#   ppio_on_ended <project> <row>   rc 0: the session is fresh again, retry the
#                                   load once; rc 1: stop the project
# The tracer default stops the project.

ppio_on_ended() { return 1; }
