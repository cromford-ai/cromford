#!/bin/bash
# tests/agent-call-ledger-client.bh-9064-test.sh — BH-9064 (slice C0): the jobs
# client of the agent-call ledger (bin/lib/jobs/agent-call-ledger.sh), the fail-
# open rules of acl_precall (bin/lib/agent-call-ledger.sh) and the knob
# registry (catalog/lanes.d/_lib.agent-call-ledger.json).
#   K1 a 404 "unknown endpoint" from the worker: ACL_DECISION=run, rc 0, 1 warn
#      line; a second 404 on the same UTC day writes none
#   K2 a 500: run, rc 0
#   K3 a timeout (AGENT_LEDGER_TIMEOUT_S=1 against a worker that answers in 3 s):
#      run, rc 0, and the request gave up near 1 s, not the 8 s JOBS_TIMEOUT
#   K4 a 200 that is not JSON: run, rc 0
#   K5 no JOBS_URL: run, rc 0, no request
#   K6 each knob's catalog default equals the code fallback in the lib and the
#      plan's prod value, and the lib sends those defaults with no knob set
#   K7 acl_req_begin / _finish / _get send the contract the route reads; a 404
#      from something that is not the worker is rc 1, a non-decision answer rc 1
#
# acl_precall runs with the REAL bin/lib/jobs/req.sh against a fake curl
# (tests/lib/ledger-worker-fake.bh-9064.sh), so the transport is the one a box
# uses. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/ledger-worker-fake.bh-9064.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'require("node:sqlite")' 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }

mkdir -p "$T/h/logs" "$T/h/flags" "$T/fakebin"
lwf_install "$T/fakebin" "$T/jobs.db"
LOG="$T/h/logs/agent-call-ledger.log"

# pre <fp> [VAR=VAL ...] — acl_precall review p1 in a subshell with the real
# transport; prints "<rc> <ACL_DECISION> <ACL_STATE> <seconds>".
pre() {
  local fp="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_BOX=box-k \
           HARNESS_SECRET=tok-fixture-bh9064 LWF_SECRET=tok-fixture-bh9064 \
           JOBS_URL=https://jobs.test LANE_GATE_DISABLE=1 LWF_REQS="$T/reqs"
    for kv in "$@"; do export "${kv?}"; done
    unset AGENT_LEDGER AGENT_LEDGER_STAGES
    . "$DIR/bin/lib/jobs/req.sh" || exit 9
    . "$DIR/bin/lib/agent-call-ledger.sh" || exit 9
    t0=$(date +%s)
    AGENT_CALL_FP="$fp" acl_precall review p1 0123456789abcdef0123; rc=$?
    echo "$rc $ACL_DECISION $ACL_STATE $(( $(date +%s) - t0 ))" )
}

# --- K1. 404: fail open, one warn line a day --------------------------------
: > "$LOG"
read -r rc dec st _ < <(pre "fp-k1a" LWF_MODE=404)
[ "$rc $dec" = "0 run" ] && ok || bad "K1a a 404 gave rc $rc decision $dec, want 0 run"
[ "$(grep -c 'WARN ROUTE MISSING' "$LOG")" = 1 ] && ok || bad "K1b first 404: $(grep -c 'WARN ROUTE MISSING' "$LOG") warn lines, want 1"
read -r rc dec st _ < <(pre "fp-k1b" LWF_MODE=404)
[ "$rc $dec" = "0 run" ] && [ "$(grep -c 'WARN ROUTE MISSING' "$LOG")" = 1 ] && ok \
  || bad "K1c a second 404 on the same day: rc $rc, $(grep -c 'WARN ROUTE MISSING' "$LOG") warn lines, want 0 and 1"
[ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "K1d a 404 wrote ALERTS.log: $(cat "$T/h/logs/ALERTS.log")"

# --- K2. 500 ----------------------------------------------------------------
read -r rc dec st _ < <(pre "fp-k2" LWF_MODE=500)
[ "$rc $dec $st" = "0 run unreadable" ] && ok || bad "K2 a 500 gave '$rc $dec $st', want '0 run unreadable'"

# --- K3. timeout ------------------------------------------------------------
read -r rc dec st secs < <(pre "fp-k3" LWF_MODE=slow LWF_SLEEP_S=3 AGENT_LEDGER_TIMEOUT_S=1)
[ "$rc $dec $st" = "0 run unreadable" ] && ok || bad "K3a a timeout gave '$rc $dec $st', want '0 run unreadable'"
[ "${secs:-99}" -le 2 ] && ok || bad "K3b the request took ${secs}s, want <= 2 (AGENT_LEDGER_TIMEOUT_S=1 is the curl -m)"

# --- K4. a 200 that is not JSON ---------------------------------------------
read -r rc dec st _ < <(pre "fp-k4" LWF_MODE=garbage)
[ "$rc $dec $st" = "0 run unreadable" ] && ok || bad "K4 a non-JSON 200 gave '$rc $dec $st', want '0 run unreadable'"

# --- K5. no JOBS_URL --------------------------------------------------------
: > "$T/reqs"
read -r rc dec st _ < <(pre "fp-k5" JOBS_URL=)
[ "$rc $dec $st" = "0 run unconfigured" ] && ok || bad "K5a no JOBS_URL gave '$rc $dec $st', want '0 run unconfigured'"
[ ! -s "$T/reqs" ] && ok || bad "K5b no JOBS_URL still sent: $(cat "$T/reqs")"

# A live worker answers run, and the row is opened (the control for K1-K5).
read -r rc dec st _ < <(pre "fp-k0")
[ "$rc $dec $st" = "0 run run" ] && ok || bad "K0 a live worker gave '$rc $dec $st', want '0 run run'"

# --- K6. the knob defaults ---------------------------------------------------
REG="$DIR/catalog/lanes.d/_lib.agent-call-ledger.json"
LIB="$DIR/bin/lib/agent-call-ledger.sh"
d() { jq -r --arg e "$1" '.libs[0].knobs[] | select(.env == $e) | .default' "$REG"; }
lib_def() { sed -n "s/^ACL_DEF_$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$LIB"; }
[ "$(jq -r '.libs[0].file' "$REG")" = bin/lib/agent-call-ledger.sh ] && ok || bad "K6a registry file is not bin/lib/agent-call-ledger.sh"
[ "$(d AGENT_LEDGER)" = 1 ] && grep -q '"${AGENT_LEDGER:-1}" = 1' "$LIB" && ok || bad "K6b AGENT_LEDGER default is not 1 in both"
for kv in WINDOW_S=3600 MAX_ATTEMPTS=3 RUNNING_TTL_S=7200 ANSWER_MAX_BYTES=262144 TIMEOUT_S=5; do
  k="${kv%%=*}" v="${kv#*=}"
  [ "$(d "AGENT_LEDGER_$k")" = "$v" ] && [ "$(lib_def "$k")" = "$v" ] && ok \
    || bad "K6c AGENT_LEDGER_$k: catalog '$(d "AGENT_LEDGER_$k")', code '$(lib_def "$k")', plan '$v'"
done
[ "$(d AGENT_LEDGER_REPLAY_STAGES)" = "$(lib_def REPLAY_STAGES)" ] && [ "$(lib_def REPLAY_STAGES)" = "review lead-review triage-shard canary mc-rereview" ] \
  && ok || bad "K6d AGENT_LEDGER_REPLAY_STAGES: catalog '$(d AGENT_LEDGER_REPLAY_STAGES)', code '$(lib_def REPLAY_STAGES)'"
: > "$T/reqs"
( unset AGENT_LEDGER_WINDOW_S AGENT_LEDGER_MAX_ATTEMPTS AGENT_LEDGER_RUNNING_TTL_S
  _jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/reqs"; JOBS_HTTP=200; printf '{"decision":"run","status":"running","attempts":1}'; return 0; }
  HARNESS="$T/h" JOBS_URL=https://jobs.test LANE_GATE_DISABLE=1
  . "$LIB" || exit 9
  AGENT_CALL_FP="fp-k6" acl_precall review p1 0123456789abcdef0123 )
read -r _m _p body < <(grep -m1 "^POST /api/agent-call-ledger/begin " "$T/reqs")
[ "$(jq -c '[.max_attempts,.window_s,.running_ttl_s,.replay]' <<<"$body" 2>/dev/null)" = '[3,3600,7200,true]' ] \
  && ok || bad "K6e the lib's code defaults differ: $(cat "$T/reqs")"

# --- K7. the request contract -----------------------------------------------
# A fake _jobs_req: records method, path and body; answers from FAKE_HTTP.
run() { # run <script> — in a subshell with the client and a fake transport
  ( FAKE_LOG="$T/req.log"
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FAKE_LOG"
      JOBS_HTTP="${FAKE_HTTP:-200}"; JOBS_BODY="${FAKE_BODY:-}"
      case "$JOBS_HTTP" in 2*) printf '%s' "$JOBS_BODY"; return 0 ;; 404) return 2 ;; *) return 1 ;; esac
    }
    _jobs_req_file() { _jobs_req "$1" "$2" "$(cat "$3")"; }
    . "$DIR/bin/lib/jobs/agent-call-ledger.sh" || exit 9
    eval "$1" )
}
: > "$T/req.log"
out=$(FAKE_BODY='{"decision":"run","status":"running","attempts":1}' JOBS_BOX=box-fixture \
  run 'acl_req_begin p1 review fp-1 3 3600 7200 1'); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .decision <<<"$out")" = run ] && ok || bad "K7a begin rc $rc out '$out'"
read -r m p body < "$T/req.log"
[ "$m $p" = "POST /api/agent-call-ledger/begin" ] && ok || bad "K7b begin request '$m $p'"
[ "$(jq -c '{project,stage,fp,max_attempts,window_s,running_ttl_s,replay,box}' <<<"$body")" \
  = '{"project":"p1","stage":"review","fp":"fp-1","max_attempts":3,"window_s":3600,"running_ttl_s":7200,"replay":true,"box":"box-fixture"}' ] \
  && ok || bad "K7c begin body '$body'"
: > "$T/req.log"
printf '{"project":"p1","stage":"review","fp":"fp-1","status":"ok","rc":0}' > "$T/fin.json"
out=$(FAKE_BODY='{"settled":true}' run "acl_req_finish '$T/fin.json'"); rc=$?
[ "$rc" = 0 ] && grep -q '^POST /api/agent-call-ledger/finish {"project":"p1"' "$T/req.log" && ok || bad "K7d finish rc $rc log $(cat "$T/req.log")"
: > "$T/req.log"
out=$(FAKE_BODY='{"row":null}' run 'acl_req_get p1 "re view" "fp#1" body'); rc=$?
[ "$rc" = 0 ] && grep -q '^GET /api/agent-call-ledger?project=p1&stage=re%20view&fp=fp%231&body=1' "$T/req.log" \
  && ok || bad "K7e get rc $rc log $(cat "$T/req.log")"
r=$(FAKE_HTTP=404 FAKE_BODY='{"error":"unknown endpoint","worker":"harness-jobs"}' run 'acl_req_begin p1 review fp-2 3 3600 7200 0' >/dev/null; echo $?)
[ "$r" = 2 ] && ok || bad "K7f a 404 unknown endpoint gave rc $r, want 2"
r=$(FAKE_HTTP=404 FAKE_BODY='{"error":"not here"}' run 'acl_req_begin p1 review fp-2 3 3600 7200 0' >/dev/null; echo $?)
[ "$r" = 1 ] && ok || bad "K7g a 404 from something that is not the worker gave rc $r, want 1"
r=$(FAKE_BODY='{"decision":"maybe"}' run 'acl_req_begin p1 review fp-2 3 3600 7200 0' >/dev/null; echo $?)
[ "$r" = 1 ] && ok || bad "K7h a non-decision answer gave rc $r, want 1"

echo "agent-call-ledger-client.bh-9064: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
