# shellcheck shell=bash
# bin/jobs-client.d/bh-9792-perf-probe-warm-get.sh — BH-9792: the warm-up
# watermark read. `perf-probe warm-get <project>` runs it (the perf-probe verb
# in bh-9786-perf-probe.sh dispatches an op to jc_verb_perf_probe_<op>).
#   GET /api/perf-probe/warm?project=<project>; prints {row: {...}|null}
# Route: worker/jobs/src/routes/perf-probe-warm.js. Caller: bin/perf-probe-warm.sh.
# rc 0 = read, 1 = transport or 5xx, 4 = a 4xx answer, an empty argument, or
# not configured (no JOBS_URL or no HARNESS_SECRET).
#: perf-probe-warm-get <project>
jc_verb_perf_probe_warm_get() {
  local rc=0 q
  [ -n "${1:-}" ] || return 4
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 4
  q=$(jq -rn --arg p "$1" '$p|@uri') || return 4
  _jobs_req GET "/api/perf-probe/warm?project=$q" || rc=$?
  printf '\n'
  [ "$rc" = 0 ] && return 0
  case "${JOBS_HTTP:-}" in 4*) return 4 ;; esac
  return 1
}
