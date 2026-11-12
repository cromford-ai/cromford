# shellcheck shell=bash
# bin/jobs-client.d/bh-9580-human-gate-put.sh — BH-9559 part A: write one
# human gate (POST /api/human-gates, worker/jobs/src/routes/human-gates.js).
# The body is the route's JSON; the answer {gate, reasked} is printed.
# rc 0 = written or re-asked, 1 = transport, 400 or not configured.
#: human-gate-put <json>
jc_verb_human_gate_put() {
  [ -n "${1:-}" ] || return 1
  _jobs_req POST /api/human-gates "$1"
}
