# owner: BH-9786.1
# shellcheck shell=bash
# bin/lib/perf-probe/budget.sh — the budget seam of the perf probe
# (sourced by bin/lib/perf-probe.sh). The tracer default: one load per route,
# and one flat budget for every route.
#   pp_loads_per_route                     how many loads per route (1)
#   pp_route_verdict <row> <route> <file>  reads the load lines of <file>
#       (`<status> <ttfb_ms> <total_ms> <bytes> <location|->`, writer ppio_load)
#       and prints the verdict line: `over|under|unmeasured` then optional
#       key=value words (ttfb_ms total_ms bytes status loads breaks outcome);
#       the lane fills a missing key from the last load line
#   pp_budgets_valid <row>                 rc 0 when the row's budgets are usable

pp_loads_per_route() { echo 1; }

pp_budgets_valid() { return 0; }

pp_route_verdict() {
  local last st tt tot by ms bytes
  last=$(grep -v '^[[:space:]]*$' "${3:-/dev/null}" 2>/dev/null | tail -n 1)
  read -r st tt tot by _ <<<"$last"
  [[ ${st:-} =~ ^[0-9]{3}$ && ${tt:-} =~ ^[0-9]+$ && ${tot:-} =~ ^[0-9]+$ && ${by:-} =~ ^[0-9]+$ ]] \
    || { echo unmeasured; return 0; }
  # Fallbacks of the lane knobs PERF_PROBE_BUDGET_MS and PERF_PROBE_BUDGET_BYTES
  # (catalog/lanes.d/perf-probe.json); bin/perf-probe.sh exports the knob values.
  ms=${PERF_PROBE_BUDGET_MS:-1000}
  bytes=${PERF_PROBE_BUDGET_BYTES:-512000}
  if [[ $st == 5* ]] || [ "$st" = 000 ] || [ "$tt" -gt "$ms" ] || [ "$tot" -gt "$ms" ] || [ "$by" -gt "$bytes" ]; then
    echo over
  else
    echo under
  fi
}
