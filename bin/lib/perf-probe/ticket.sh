# owner: BH-9786.5
# shellcheck shell=bash
# bin/lib/perf-probe/ticket.sh — the ticket seam of the perf probe (sourced by
# bin/lib/perf-probe.sh).
#   pp_ticket_step <project> <row> <day> <rundir>   prints ticket=<action>
# The tracer default files nothing: ticket=none.

pp_ticket_step() { echo ticket=none; }
