# shellcheck shell=bash
# bin/jobs-client.d/bh-9786-perf-probe.sh — BH-9786: the perf probe verb.
#   perf-probe results-put <json>   POST /api/perf-probe/results; the answer
#                                   {written: <n>} is printed.
# Route: worker/jobs/src/routes/perf-probe.js. Caller: bin/perf-probe.sh.
# rc 0 = written, 1 = transport or 5xx, 4 = a 4xx answer, an empty argument,
# an unknown op, or not configured (no JOBS_URL or no HARNESS_SECRET).
# A LATER OP lives in its own fragment, never here: a file
# bin/jobs-client.d/<key>-perf-probe-<op>.sh that defines the verb
# jc_verb_perf_probe_<op> (each - as _). `perf-probe <op> ...` runs it, because
# the client sources every fragment before it dispatches.
#: perf-probe <op> <json>
jc_verb_perf_probe() {
  local op="${1:-}" rc=0
  shift 2>/dev/null || true
  case "$op" in
    results-put)
      [ -n "${1:-}" ] || return 4
      [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 4
      _jobs_req POST /api/perf-probe/results "$1" || rc=$?
      printf '\n'
      [ "$rc" = 0 ] && return 0
      case "${JOBS_HTTP:-}" in 4*) return 4 ;; esac
      return 1 ;;
  esac
  if [[ $op =~ ^[a-z][a-z0-9-]*$ ]] && declare -F "jc_verb_perf_probe_${op//-/_}" >/dev/null; then
    "jc_verb_perf_probe_${op//-/_}" "$@"; return $?
  fi
  echo "usage: jobs-client.sh perf-probe results-put <json>" >&2
  return 4
}
