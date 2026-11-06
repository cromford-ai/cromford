# shellcheck shell=bash
# bin/lib/jobs/agent-call-ledger.sh — the jobs-worker client of the agent-call
# ledger (BH-9064, worker/jobs/src/routes/agent-call-ledger.js). Sourced by
# bin/lib/agent-call-ledger.sh, which needs _jobs_req (bin/lib/jobs/req.sh,
# loaded by bin/jobs-client.sh). Not a jobs-client module: only agent-call.sh
# and claude-cost.sh use it, so jobs-client.sh's module list stays unchanged.
#
#   acl_req_begin <project> <stage> <fp> <max> <window-s> <ttl-s> <replay 0|1>
#   acl_req_finish <json-body-file>
#   acl_req_get <project> <stage> <fp> [body]
# Each one: rc 0 and the answer JSON on stdout when the worker ANSWERED; rc 2
# when it answered 404 "unknown endpoint" (the route is not deployed: a box
# synced ahead of the worker), the same contract as call_guard_claim; rc 1 for
# anything else (transport, timeout, 5xx, no JOBS_URL).

# _acl_req_rc — map a _jobs_req failure to 1 or 2 (route missing).
_acl_req_rc() {
  [ "$1" = 2 ] && [ "${JOBS_HTTP:-}" = 404 ] \
    && printf '%s' "${JOBS_BODY:-}" | jq -e '.worker == "harness-jobs"' >/dev/null 2>&1 && return 2
  return 1
}

acl_req_begin() {
  local body f resp rc
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  body=$(jq -nc --arg p "$1" --arg s "$2" --arg f "$3" --arg m "${4:-}" --arg w "${5:-}" --arg t "${6:-}" \
    --arg r "${7:-0}" --arg b "${JOBS_BOX:-}" \
    '{project:$p,stage:$s,fp:$f,max_attempts:($m|tonumber? // null),window_s:($w|tonumber? // null),
      running_ttl_s:($t|tonumber? // null),replay:($r=="1"),box:$b}' 2>/dev/null) || return 1
  # Not inside $( ): JOBS_HTTP / JOBS_BODY are set in THIS shell by _jobs_req.
  f=$(mktemp "${TMPDIR:-/tmp}/acl-begin.XXXXXX") || return 1
  _jobs_req POST /api/agent-call-ledger/begin "$body" > "$f"; rc=$?
  resp=$(cat "$f" 2>/dev/null); rm -f "$f"
  [ "$rc" = 0 ] || { _acl_req_rc "$rc"; return; }
  printf '%s' "$resp" | jq -e '.decision | IN("run","replay","terminal")' >/dev/null 2>&1 || return 1
  printf '%s' "$resp"
}

# The body rides in a file: an answer can be far over the argv cap.
acl_req_finish() {
  local rc f
  [ -s "${1:-}" ] || return 1
  command -v _jobs_req_file >/dev/null 2>&1 || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/acl-finish.XXXXXX") || return 1
  _jobs_req_file POST /api/agent-call-ledger/finish "$1" > "$f"; rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f"
  [ "$rc" = 0 ] || { _acl_req_rc "$rc"; return; }
}

acl_req_get() {
  local q f rc
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  q="project=$(jq -rn --arg v "$1" '$v|@uri')&stage=$(jq -rn --arg v "$2" '$v|@uri')&fp=$(jq -rn --arg v "$3" '$v|@uri')"
  [ "${4:-}" = body ] && q="$q&body=1"
  f=$(mktemp "${TMPDIR:-/tmp}/acl-get.XXXXXX") || return 1
  _jobs_req GET "/api/agent-call-ledger?$q" > "$f"; rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f"
  [ "$rc" = 0 ] || { _acl_req_rc "$rc"; return; }
}
