# shellcheck shell=bash
# bin/lib/perf-probe.sh — BH-9786: the pure half of the daily perf probe
# (bin/perf-probe.sh). Sourced, never executed: no `exit`, no `set`, no output
# at source time. The root is ${HARNESS:-${H:-}} (never a literal default).
#
#   pp_row_valid <file>        rc 0 when catalog/perf-probe.d/<project>.json is a
#                              usable row; else prints the reason, rc 1
#   pp_routes <project> <row>  the paths to load, one per line (pp_routes_expand).
#                              A line that starts with `!incomplete` is a marker,
#                              not a route: it makes the run incomplete.
#
# The row: {project, enabled, base_url, session_path, signin_path, roles[],
# routes[], budgets{}}. project equals the file name. base_url is
# https://<host>[:port] with no path, or http://127.0.0.1[:port] only when
# PERF_PROBE_ALLOW_LOOPBACK=1 (the test fake). Each path field starts with `/`.
#
# THE SEAMS. At the end this file sources every bin/lib/perf-probe/*.sh in
# LC_ALL=C name order. Each seam file is owned by one child of BH-9786 and
# holds a no-op default in the tracer (BH-9786.0):
#   budget.sh       pp_loads_per_route, pp_route_verdict, pp_budgets_valid
#   routes.sh       pp_routes_expand
#   session-end.sh  ppio_on_ended
#   statements.sh   pp_statements_run, pp_findings_extra
#   ticket.sh       pp_ticket_step
# A later file in name order overrides an earlier one. A seam that fails to
# load fails the source of this file (rc 1).
# Note: docs/notes/2026-11-17-BH-9786-perf-probe.md.

# A path field: starts with `/`, no space, quote, backslash or control byte (it
# goes into a URL and a curl argument).
_pp_path_ok() { [[ ${1:-} =~ ^/[^[:space:][:cntrl:]\"\\]*$ ]]; }

pp_row_valid() {
  local f="${1:-}" want got bu p
  [ -r "$f" ] || { echo "unreadable"; return 1; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "not a JSON object"; return 1; }
  want=$(basename "$f" .json)
  got=$(jq -r 'if (.project|type) == "string" then .project else "" end' "$f")
  [ "$got" = "$want" ] || { echo "project '$got' is not the file name '$want'"; return 1; }
  bu=$(jq -r 'if (.base_url|type) == "string" then .base_url else "" end' "$f")
  if [[ $bu =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; then :
  elif [ "${PERF_PROBE_ALLOW_LOOPBACK:-0}" = 1 ] && [[ $bu =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?$ ]]; then :
  else echo "base_url '$bu' is not https://<host>"; return 1; fi
  for p in session_path signin_path; do
    if jq -e --arg k "$p" 'has($k)' "$f" >/dev/null 2>&1; then
      _pp_path_ok "$(jq -r --arg k "$p" 'if (.[$k]|type) == "string" then .[$k] else "" end' "$f")" \
        || { echo "$p does not start with /"; return 1; }
    fi
  done
  jq -e '(.roles|type) == "array" and all(.roles[]; type == "string")' "$f" >/dev/null 2>&1 \
    || { echo "roles is not an array of strings"; return 1; }
  jq -e '(.routes|type) == "array" and all(.routes[]; type == "string")' "$f" >/dev/null 2>&1 \
    || { echo "routes is not an array of strings"; return 1; }
  while IFS= read -r p; do
    _pp_path_ok "$p" || { echo "route '$p' does not start with /"; return 1; }
  done < <(jq -r '.routes[]' "$f")
  p=$(pp_budgets_valid "$f") || { echo "budgets: ${p:-invalid}"; return 1; }
  return 0
}

pp_routes() { pp_routes_expand "$@"; }

_pp_seams=("$(dirname "${BASH_SOURCE[0]}")"/perf-probe/*.sh)
while IFS= read -r _pp_seam; do
  [ -f "$_pp_seam" ] || continue
  # shellcheck source=/dev/null
  . "$_pp_seam" || { unset _pp_seams _pp_seam; return 1; }
done < <(printf '%s\n' "${_pp_seams[@]}" | LC_ALL=C sort)
unset _pp_seams _pp_seam
