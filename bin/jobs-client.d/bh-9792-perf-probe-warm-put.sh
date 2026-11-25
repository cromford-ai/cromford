# shellcheck shell=bash
# bin/jobs-client.d/bh-9792-perf-probe-warm-put.sh — BH-9792: the warm-up
# watermark write. `perf-probe warm-put <json>` runs it (the perf-probe verb in
# bh-9786-perf-probe.sh dispatches an op to jc_verb_perf_probe_<op>).
#   POST /api/perf-probe/warm {project, deployment_id, outcome, routes, over};
#   prints {created: 1|0}
# Route: worker/jobs/src/routes/perf-probe-warm.js. Caller: bin/perf-probe-warm.sh.
# rc 0 = written (or already there), 1 = transport or 5xx, 4 = a 4xx answer,
# an empty argument, or not configured (no JOBS_URL or no HARNESS_SECRET).
#: perf-probe-warm-put <json>
jc_verb_perf_probe_warm_put() {
  local rc=0
  [ -n "${1:-}" ] || return 4
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 4
  _jobs_req POST /api/perf-probe/warm "$1" || rc=$?
  printf '\n'
  [ "$rc" = 0 ] && return 0
  case "${JOBS_HTTP:-}" in 4*) return 4 ;; esac
  return 1
}
