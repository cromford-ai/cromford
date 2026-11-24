# owner: BH-9786.2
# shellcheck shell=bash
# bin/lib/perf-probe/routes.sh — the route seam of the perf probe (sourced by
# bin/lib/perf-probe.sh). The tracer default: the row's static routes.
#   pp_routes_expand <project> <row>   one path per line; a line that starts
#                                      with `!incomplete` marks the run incomplete

pp_routes_expand() { jq -r '.routes[]' "$2"; }
