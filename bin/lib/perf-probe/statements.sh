# owner: BH-9786.4
# shellcheck shell=bash
# bin/lib/perf-probe/statements.sh — the slow-statements seam of the perf
# probe (sourced by bin/lib/perf-probe.sh).
#   pp_statements_run <project> <row> <rundir> <day>   prints stmts_new=<n>
#   pp_findings_extra <project> ...                    extra finding lines
# The tracer default reads nothing: stmts_new=0 and no finding.

pp_statements_run() { echo stmts_new=0; }

pp_findings_extra() { :; }
