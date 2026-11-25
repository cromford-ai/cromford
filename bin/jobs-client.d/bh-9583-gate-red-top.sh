# shellcheck shell=bash
# bin/jobs-client.d/bh-9583-gate-red-top.sh — BH-9583: the suites that turned
# the most builds of <repo> GATE_RED in the last <days> days, top <n>
# (GET /api/gate-red/top, worker/jobs/src/routes/gate-red-rank.js). The answer
# JSON {repo, days, n, since, rows_read, suites: [{suite, count, last_at}]} is
# printed. The reader is bin/test-impact-gate.sh (tier topred).
# rc 0 = answer, 1 = a bad arg, transport, non-2xx or not configured.
#: gate-red-top <repo> <n> <days>
jc_verb_gate_red_top() {
  local repo="${1:-}" n="${2:-}" days="${3:-}" enc
  [ -n "$repo" ] || return 1
  case "$n" in ''|*[!0-9]*|0*) return 1 ;; esac
  case "$days" in ''|*[!0-9]*|0*) return 1 ;; esac
  enc=$(jq -rn --arg v "$repo" '$v|@uri' 2>/dev/null) && [ -n "$enc" ] || return 1
  _jobs_req GET "/api/gate-red/top?repo=$enc&n=$n&days=$days"
}
