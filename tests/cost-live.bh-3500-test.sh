#!/bin/bash
# tests/cost-live.bh-3500-test.sh — the LIVE COST METER and the BOUNDARY PUSH
# (BH-3500, slice BH-3481.3): the bodies of bin/lib/cost-live.sh.
#
#   C1 cost_live_row: one stable row per (box, session), 16 columns, an
#      unpriced model is null and never 0, a garbled line is no row
#   C2 cost_live_on says why it is off, once per process
#   C3/C4 the sandbox and PROJECT=testproj never POST (and a control that does)
#   C5 the boundary push spawns cost-rows-push.sh once per call, dedupes on the
#      cron lane's lock, and has its own off switch
#   C6 an unreadable transcript is one log line and the meter keeps polling
#   C7 through the REAL bin/agent-call.sh: a long-running session pushes a live
#      row BEFORE it ends, with the same session id as its final cost row
#   C8 a lib.cost-live.* settings row sets the push interval
#   C9 the tripwire hook stops the session and writes $OUT.tripwire
#   C10 an --advisor attempt's advisor spend is in the live row and the tripwire's usd
#   G  the knob manifest composes and every knob is read by the lib
#
# Nothing here reaches a network: _jobs_req is a shell stub in the unit cases,
# and C7's curl is a shim first on PATH answering for http://jobs.invalid.
# Run from anywhere: tests/cost-live.bh-3500-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
LIB="$DIR/bin/lib/cost-live.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/state" "$T/logs" "$T/locks"
echo box-t > "$T/state/box-id"
export HARNESS="$T"
# The suite's own shell is the caller: agent-call's names, set the same way.
runner=claude PROJECT=freeproj STAGE=execute
unset OUT COST_RUN_ID COST_KEY AGENT_CALL_TICKET HARNESS_TICKET KEY COST_LIVE COST_LIVE_PUSH_S COST_LIVE_POLL_S COST_ROWS_PUSH_AT_BOUNDARY
# shellcheck source=bin/lib/cost-row.sh
. "$DIR/bin/lib/cost-row.sh" || { echo "could not source bin/lib/cost-row.sh"; exit 1; }
# shellcheck source=bin/lib/cost-live.sh
. "$LIB" || { echo "could not source $LIB"; exit 1; }
# The jobs client, stubbed: method, path and body to a file, a chosen answer.
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/posts.log"
  JOBS_HTTP="${STUB_HTTP:-200}"
  return "${STUB_RC:-0}"
}
TC="100|20|300|4|0.5|claude-fable-5-1|3|1|"

# mk_tree <dir> <transcript-cost body> — a bin/ with this lib and a stub reader
# beside it, which is where the lib looks first.
mk_tree() {
  mkdir -p "$1/bin/lib"; cp "$LIB" "$1/bin/lib/cost-live.sh"
  printf '#!/bin/bash\n%s\n' "$2" > "$1/bin/transcript-cost.sh"; chmod +x "$1/bin/transcript-cost.sh"
}
# wait_until <tenths> <cmd...> — poll a condition, 0 when it held in time.
wait_until() { local n="$1"; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n-1)); done; "$@"; }

# =============================================================================
# C1 — the row
# =============================================================================
R1=$(cost_live_row box-t s1 "$TC"); R1RC=$?
R1B=$(cost_live_row box-t s1 "$TC")
R2=$(cost_live_row box-t s2 "$TC")
WANTH=$(printf 'live|box-t|s1' | sha256sum | cut -d' ' -f1)
[ "$R1RC" = 0 ] && [ -n "$R1" ] && ok || bad "C1 cost_live_row gave rc=$R1RC '$R1'"
H1=$(jq -r '.row_hash' <<<"$R1" 2>/dev/null)
[ "$H1" = "$WANTH" ] && ok || bad "C1 row_hash '$H1', want sha256(live|box-t|s1)=$WANTH"
[ "$H1" = "$(jq -r '.row_hash' <<<"$R1B" 2>/dev/null)" ] && ok || bad "C1 row_hash not stable across calls"
H2=$(jq -r '.row_hash' <<<"$R2" 2>/dev/null)
[ -n "$H2" ] && [ "$H2" != "$H1" ] && ok || bad "C1 s2 hash '$H2' is not distinct from s1's"
jq -e '.cost_usd == 0.5 and .input_toks == 100 and .output_toks == 20 and .cache_read == 300 and .cache_write == 4
       and .model == "claude-fable-5-1" and .box == "box-t" and .session_id == "s1"
       and .project == "freeproj" and .stage == "execute" and .unpriced == null and .run_id == null' <<<"$R1" >/dev/null 2>&1 \
  && ok || bad "C1 field values wrong: $R1"
R3=$(OUT="$T/builds/proj-X-1/execute.out" HARNESS_TICKET=BH-7 cost_live_row box-t s1 "$TC")
jq -e '.run_id == "proj-X-1" and .ticket == "BH-7"' <<<"$R3" >/dev/null 2>&1 && ok || bad "C1 run_id/ticket from \$OUT/HARNESS_TICKET: $R3"
R4=$(COST_RUN_ID=run-9 OUT="$T/builds/proj-X-1/execute.out" cost_live_row box-t s1 "$TC")
[ "$(jq -r .run_id <<<"$R4" 2>/dev/null)" = run-9 ] && ok || bad "C1 COST_RUN_ID does not win: $R4"
R5=$(cost_live_row box-t s1 "100|20|300|4||claude-x-9|3|1|claude-x-9")
jq -e '.cost_usd == null and .unpriced == "claude-x-9"' <<<"$R5" >/dev/null 2>&1 && ok || bad "C1 unpriced row: $R5"
R6=$(cost_live_row box-t s1 "100|20|300|4|n/a|claude-x-9|3|1|")
jq -e '.cost_usd == null' <<<"$R6" >/dev/null 2>&1 && ok || bad "C1 a non-numeric usd is not null: $R6"
R7=$(cost_live_row box-t s1 "1x0|20|300|4|0.5|m|3|1|"); R7RC=$?
[ "$R7RC" = 1 ] && [ -z "$R7" ] && ok || bad "C1 a non-integer token field gave rc=$R7RC '$R7'"
R8=$(cost_live_row "" s1 "$TC"); R8RC=$?; R9=$(cost_live_row box-t "" "$TC"); R9RC=$?
[ "$R8RC" = 1 ] && [ -z "$R8" ] && [ "$R9RC" = 1 ] && [ -z "$R9" ] && ok || bad "C1 empty box/sid made a row"
KEYS=$(jq -c 'keys|sort' <<<"$R1" 2>/dev/null)
WANTK='["box","cache_read","cache_write","cost_usd","input_toks","model","output_toks","project","row_hash","run_id","session_id","stage","started_at","ticket","unpriced","updated_at"]'
[ "$KEYS" = "$WANTK" ] && ok || bad "C1 columns $KEYS, want $WANTK"
jq -e '.updated_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<<"$R1" >/dev/null 2>&1 && ok || bad "C1 updated_at: $R1"

# =============================================================================
# C2 — off without a secret, and it says why, once
# =============================================================================
rm -f "$T/logs/claude-cost.log"
C2=$( unset HARNESS_TEST_SANDBOX HARNESS_SECRET; JOBS_URL=http://jobs.invalid LANE_GATE_DISABLE=1
  cost_live_on; echo "rc=$? off=$CL_OFF"
  cost_live_on; echo "rc2=$? off2=$CL_OFF" )
grep -qx 'rc=1 off=no-secret' <<<"$C2" && grep -qx 'rc2=1 off2=no-secret' <<<"$C2" && ok || bad "C2 got: $C2"
N2=$(grep -c 'cost live: OFF (no-secret)' "$T/logs/claude-cost.log" 2>/dev/null)
[ "$N2" = 1 ] && ok || bad "C2 OFF lines in claude-cost.log: ${N2:-0}, want exactly 1"
# every other reason, one each
off_why() { ( "$@"; export LANE_GATE_DISABLE=1; cost_live_on; echo "$?:$CL_OFF" ); }
[ "$(off_why eval 'unset HARNESS_TEST_SANDBOX; HARNESS_SECRET=x JOBS_URL=http://jobs.invalid COST_LIVE=0')" = 1:knob ] && ok || bad "C2 COST_LIVE=0 is not off:knob"
[ "$(off_why eval 'unset HARNESS_TEST_SANDBOX; HARNESS_SECRET=x JOBS_URL=')" = 1:no-jobs-url ] && ok || bad "C2 empty JOBS_URL is not off:no-jobs-url"
[ "$(off_why eval 'unset HARNESS_TEST_SANDBOX; HARNESS_SECRET=x JOBS_URL=http://jobs.invalid runner=codex')" = 1:runner=codex ] && ok || bad "C2 runner=codex is not off:runner=codex"
[ "$(off_why eval 'unset HARNESS_TEST_SANDBOX HARNESS; HARNESS_SECRET=x JOBS_URL=http://jobs.invalid')" = 1:no-root ] && ok || bad "C2 no root is not off:no-root"
[ "$(off_why eval 'unset HARNESS_TEST_SANDBOX; HARNESS_SECRET=x JOBS_URL=http://jobs.invalid')" = 0: ] && ok || bad "C2 everything valid is not ON: $(off_why eval 'unset HARNESS_TEST_SANDBOX; HARNESS_SECRET=x JOBS_URL=http://jobs.invalid')"

# =============================================================================
# C3 — the sandbox never POSTs
# =============================================================================
rm -f "$T/posts.log"
C3=$( export HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=x JOBS_URL=http://jobs.invalid LANE_GATE_DISABLE=1
  cost_live_on; echo "on=$?:$CL_OFF"
  cost_live_push "$(cost_live_row box-t s1 "$TC")"; echo "push=$?" )
grep -qx 'on=1:sandbox' <<<"$C3" && grep -qx 'push=0' <<<"$C3" && ok || bad "C3 got: $C3"
[ -s "$T/posts.log" ] && bad "C3 the sandbox POSTed: $(cat "$T/posts.log")" || ok

# =============================================================================
# C4 — PROJECT=testproj never POSTs; the control proves the stub sees a POST
# =============================================================================
rm -f "$T/posts.log"
C4=$( unset HARNESS_TEST_SANDBOX; export HARNESS_SECRET=x JOBS_URL=http://jobs.invalid LANE_GATE_DISABLE=1
  PROJECT=testproj cost_live_on; echo "on=$?:$CL_OFF"
  cost_live_push "$(PROJECT=testproj cost_live_row box-t s1 "$TC")"; echo "push=$?" )
grep -qx 'on=1:testproj' <<<"$C4" && grep -qx 'push=0' <<<"$C4" && ok || bad "C4 got: $C4"
[ -s "$T/posts.log" ] && bad "C4 a testproj row was POSTed: $(cat "$T/posts.log")" || ok
( unset HARNESS_TEST_SANDBOX; cost_live_push "$(cost_live_row box-t s1 "$TC")" )
N4=$(grep -c '^POST /api/cost/live ' "$T/posts.log" 2>/dev/null)
[ "$N4" = 1 ] && ok || bad "C4 control: POSTs to /api/cost/live: ${N4:-0}, want 1"
B4=$(sed -n 's#^POST /api/cost/live ##p' "$T/posts.log" 2>/dev/null | head -1)
jq -e '.box == "box-t" and (.rows|length) == 1 and .rows[0].session_id == "s1"' <<<"$B4" >/dev/null 2>&1 \
  && ok || bad "C4 control body: $B4"
# a failed push is one log line, rc 0; a 404 says the route is not deployed
rm -f "$T/logs/cost-live.log"
( unset HARNESS_TEST_SANDBOX; STUB_RC=2 STUB_HTTP=404 cost_live_push "$(cost_live_row box-t s1 "$TC")"; echo "rc=$?" > "$T/c4rc" )
[ "$(cat "$T/c4rc")" = rc=0 ] && ok || bad "C4 a failed push returned $(cat "$T/c4rc")"
grep -q 'push FAILED session=s1 http=404 (route not deployed yet) rc=2' "$T/logs/cost-live.log" 2>/dev/null \
  && ok || bad "C4 404 log line: $(cat "$T/logs/cost-live.log" 2>/dev/null)"
[ "$(cost_live_push 'not json'; echo $?)" = 0 ] && ok || bad "C4 a non-JSON row did not answer rc 0"

# =============================================================================
# C5 — the boundary push
# =============================================================================
mkdir -p "$T/fakebin" "$T/bin" "$T/.claude/projects/-work"
cat > "$T/budgets.json" <<'EOF'
{"_units":"input_toks + cache_read","lanes":[
 {"lane":"free-lane","stage":"execute","project":"freeproj","ceiling_tokens":200000,
  "target_tokens":1000,"composition":[],"bounds":["[lane:none] none, by design PENDING"]}]}
EOF
# the bh-653 stub claude: a transcript line, an optional nap, the envelope
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
PROJ="$HOME/.claude/projects/-work"; mkdir -p "$PROJ"
printf '{"type":"assistant","uuid":"u-1","timestamp":"2026-09-17T18:00:00Z","message":{"id":"msg_1","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$PROJ/$sid.jsonl"
if [ -n "${STUB_LIVE_WAIT_S:-}" ]; then # BH-9971: wait for the first live POST, bounded, not a fixed nap
  n=$(( STUB_LIVE_WAIT_S * 10 ))
  while [ "$n" -gt 0 ] && ! grep -q ' http://jobs.invalid/api/cost/live ' "$T_DIR/curl.log" 2>/dev/null; do
    sleep 0.1; n=$(( n - 1 ))
  done
else
  sleep "${STUB_NAP:-0}"
fi
date +%s.%N > "$T_DIR/stub.end" # determinism: ok the test compares two wall-clock stamps it takes itself
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# curl: every request to a file with its body, answered {} 200
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" body="" prev=""
for a in "$@"; do
  case "$prev" in --data-binary|-d) body="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s %s %s\n' "$(date +%s.%N)" "$url" "$body" >> "$T_DIR/curl.log" # determinism: ok ordering stamp the test compares to stub.end
printf '{}\n200'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

# ac <agent-call> <out> [VAR=VAL ...] -> rc; the real agent-call, stub vendors
ac() {
  local a="$1" o="$2"; shift 2
  ( unset AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID OUT
    export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" COST_TRANSCRIPT_ROWS=1 CALL_GUARD=0 \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= ACCOUNT_ROUTING=0 LADDER_TIER2_GROK=0 \
           LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 IRON_LAW_LANES=none "$@"
    cd "$T" && bash "$a" execute freeproj claude-fable-5-1 60 "$o" "hi" >/dev/null 2>"$T/ac.err" )
  echo $?
}
rm -rf "$T/tree"; mkdir -p "$T/tree"; cp -R "$DIR/bin" "$T/tree/bin"
printf '#!/bin/bash\necho "spawn $*" >> "%s/spawns.log"\n' "$T" > "$T/tree/bin/cost-rows-push.sh"
chmod +x "$T/tree/bin/cost-rows-push.sh"
rm -f "$T/spawns.log"; mkdir -p "$T/builds/freeproj-BH-1-1"
R5=$(ac "$T/tree/bin/agent-call.sh" "$T/builds/freeproj-BH-1-1/execute.out" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=x JOBS_URL=http://jobs.invalid)
[ "$R5" = 0 ] && ok || bad "C5 agent-call rc=$R5: $(head -c 400 "$T/ac.err")"
wait_until 50 test -s "$T/spawns.log"
[ "$(grep -c . "$T/spawns.log" 2>/dev/null)" = 1 ] && ok || bad "C5 spawns after one call: $(cat "$T/spawns.log" 2>/dev/null)"
grep -qx 'spawn box-t' "$T/spawns.log" 2>/dev/null && ok || bad "C5 the spawn does not name box-t: $(cat "$T/spawns.log" 2>/dev/null)"
# the lock is held: dedupe, never wait
rm -f "$T/spawns.log" "$T/logs/cost-live.log"
# -o: the lock stays with flock, not its sleep, so killing flock frees it
flock -o "$T/locks/cost-rows-push.lock" sleep 8 & HOLD=$!
wait_until 50 eval '! flock -n "$T/locks/cost-rows-push.lock" true'
( export HARNESS_SECRET=x JOBS_URL=http://jobs.invalid; . "$T/tree/bin/lib/cost-live.sh"; cost_live_boundary_push )
sleep 0.5
grep -q 'boundary push skipped (push in flight)' "$T/logs/cost-live.log" 2>/dev/null && ok || bad "C5 no 'skipped (push in flight)' line: $(cat "$T/logs/cost-live.log" 2>/dev/null)"
[ -s "$T/spawns.log" ] && bad "C5 a push was spawned while the lock was held" || ok
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
# the switch: no spawn, no line
rm -f "$T/spawns.log" "$T/logs/cost-live.log"
( export HARNESS_SECRET=x JOBS_URL=http://jobs.invalid COST_ROWS_PUSH_AT_BOUNDARY=0; . "$T/tree/bin/lib/cost-live.sh"; cost_live_boundary_push )
sleep 0.5
[ -s "$T/spawns.log" ] || [ -s "$T/logs/cost-live.log" ] && bad "C5 COST_ROWS_PUSH_AT_BOUNDARY=0 still spawned/logged" || ok
# no secret (every suite in CI): nothing spawned into a scratch tree
( unset HARNESS_SECRET; . "$T/tree/bin/lib/cost-live.sh"; cost_live_boundary_push )
sleep 0.5
[ -s "$T/spawns.log" ] && bad "C5 a push was spawned with no HARNESS_SECRET" || ok
# control for the above: the same direct call with the lock free DOES spawn
( export HARNESS_SECRET=x JOBS_URL=http://jobs.invalid; . "$T/tree/bin/lib/cost-live.sh"; cost_live_boundary_push )
wait_until 50 test -s "$T/spawns.log" && ok || bad "C5 control: a direct call with the lock free spawned nothing"

# =============================================================================
# C6 — an unreadable transcript: one line, and the meter keeps polling
# =============================================================================
mk_tree "$T/t6" "echo x >> \"$T/tc6.calls\"; exit 3"
rm -f "$T/logs/cost-live.log" "$T/posts.log" "$T/tc6.calls"
# BH-9971: the session pid lives until the reader was polled 3 times (bounded 30 s), not a fixed 4 s
( n=300; while [ "$n" -gt 0 ]; do c=$(grep -c . "$T/tc6.calls" 2>/dev/null); [ "${c:-0}" -ge 3 ] && break; sleep 0.1; n=$(( n - 1 )); done ) & P6=$!
( unset HARNESS_TEST_SANDBOX; export HARNESS_SECRET=x JOBS_URL=http://jobs.invalid COST_LIVE_POLL_S=1 COST_LIVE_PUSH_S=1
  . "$T/t6/bin/lib/cost-live.sh"; cost_live_meter "$P6" s-missing "$T" ) & M6=$!
wait_until 100 eval '! kill -0 "$M6" 2>/dev/null' && ok || { bad "C6 the meter did not return after its pid died"; kill "$M6" 2>/dev/null; }
wait "$P6" 2>/dev/null
[ "$(grep -c 'could not read session s-missing' "$T/logs/cost-live.log" 2>/dev/null)" = 1 ] && ok || bad "C6 read-failure lines: $(cat "$T/logs/cost-live.log" 2>/dev/null)"
N6=$(grep -c . "$T/tc6.calls" 2>/dev/null); [ "${N6:-0}" -ge 3 ] && ok || bad "C6 the reader was polled $(grep -c . "$T/tc6.calls" 2>/dev/null) times, want >= 3"
[ -s "$T/posts.log" ] && bad "C6 an unreadable session POSTed" || ok

# =============================================================================
# C7 — end to end through the real bin/agent-call.sh
# =============================================================================
# The jobs client the real agent-call sources from $HARNESS/bin, so _jobs_req is
# real and its curl is the shim.
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"; cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"; cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
c7() { # c7 <agent-call> <build> [stub-wait-s] -> rc; the stub ends at the first live POST or the bound
  rm -f "$T/curl.log" "$T/stub.end"; rm -rf "${T:?}/builds/$2"; mkdir -p "$T/builds/$2"
  ( unset HARNESS_TEST_SANDBOX
    ac "$1" "$T/builds/$2/execute.out" HARNESS_SECRET=x JOBS_URL=http://jobs.invalid \
       COST_ROWS_PUSH_AT_BOUNDARY=0 COST_LIVE_PUSH_S=1 COST_LIVE_POLL_S=1 STUB_LIVE_WAIT_S="${3:-60}" )
}
R7=$(c7 "$DIR/bin/agent-call.sh" freeproj-BH-1-1 60)
O7="$T/builds/freeproj-BH-1-1/execute.out"
[ "$R7" = 0 ] && [ "$(cat "$O7" 2>/dev/null)" = "CLEAN DONE" ] && ok || bad "C7 rc=$R7 out='$(cat "$O7" 2>/dev/null)': $(head -c 400 "$T/ac.err")"
END7=$(cat "$T/stub.end" 2>/dev/null)
LIVE7=$(grep ' http://jobs.invalid/api/cost/live ' "$T/curl.log" 2>/dev/null)
EARLY7=$(awk -v e="${END7:-0}" '$1 < e' <<<"$LIVE7" | head -1)
[ -n "$EARLY7" ] && ok || bad "C7 no /api/cost/live POST before the session ended (end=$END7): $(cut -c1-200 <<<"$LIVE7")"
LSID=$(cut -d' ' -f3- <<<"$EARLY7" | jq -r '.rows[0].session_id' 2>/dev/null)
CSID=$(tail -n +2 "$T/builds/freeproj-BH-1-1/cost.csv" 2>/dev/null | cut -d, -f17 | tail -1)
[ -n "$LSID" ] && [ "$LSID" = "$CSID" ] && ok || bad "C7 live session '$LSID' is not the final row's '$CSID'"
[ "$(awk -F, -v s="$CSID" 'NR>1 && $17==s' "$T/builds/freeproj-BH-1-1/cost.csv" 2>/dev/null | grep -c .)" = 1 ] \
  && ok || bad "C7 cost.csv rows for the session: $(cat "$T/builds/freeproj-BH-1-1/cost.csv" 2>/dev/null)"
cut -d' ' -f3- <<<"$EARLY7" | jq -e '.rows[0].run_id == "freeproj-BH-1-1" and .rows[0].box == "box-t" and .rows[0].input_toks == 5000' >/dev/null 2>&1 \
  && ok || bad "C7 live row: $(cut -d' ' -f3- <<<"$EARLY7")"
sleep 0.3
pgrep -f "$O7" >/dev/null 2>&1 && bad "C7 a process still carries \$OUT after the call (a meter survived): $(pgrep -af "$O7")" || ok
# D1: the same run with the meter's push line deleted pushes nothing live
rm -rf "$T/c7m"; mkdir -p "$T/c7m"; cp -R "$DIR/bin" "$T/c7m/bin"
sed -i '/row=$(cost_live_row "$box" "$sid" "$line") && cost_live_push "$row"/d' "$T/c7m/bin/lib/cost-live.sh"
if cmp -s "$LIB" "$T/c7m/bin/lib/cost-live.sh"; then
  bad "C7-mut the push line was not found in the meter (the mutation proves nothing)"
else
  R7M=$(c7 "$T/c7m/bin/agent-call.sh" freeproj-BH-1-2 3) # the bound exit: no live POST comes
  [ "$R7M" = 0 ] && ok || bad "C7-mut rc=$R7M"
  grep -q ' http://jobs.invalid/api/cost/live ' "$T/curl.log" 2>/dev/null \
    && bad "C7-mut a live row was POSTed with the meter's push deleted" || ok
fi

# =============================================================================
# C8 — a settings row sets the push interval
# =============================================================================
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  && ok || bad "C8/G lanes-build.sh did not compose a registry"
mk_tree "$T/t8" "n=\$(( \$(cat \"$T/tc8.n\" 2>/dev/null || echo 0) + 1 )); echo \$n > \"$T/tc8.n\"
[ \$n -ge 40 ] && kill \$(cat \"$T/p8.pid\"); echo '1|1|1|1|0.1|m|1|1|'"
# The fake clock: 1000 at the meter's start, +10 s per poll. Each read of the
# transcript is one poll, so the clock is the reader's call count.
c8() { # c8 <cache-json|none> -> the COST_LIVE_PUSH_S applied; push clocks in $T/pushes
  rm -rf "$T/state/lane-gate" "$T/state/settings-cache.json" "$T/pushes" "$T/tc8.n"
  [ "$1" = none ] || printf '%s\n' "$1" > "$T/state/settings-cache.json"
  sleep 30 & echo $! > "$T/p8.pid"
  ( unset COST_LIVE_PUSH_S COST_LIVE_POLL_S JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE OUT
    export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW=1000000 HARNESS_ENV_DIR="$T/noenv"
    . "$DIR/bin/lib/lane-gate.sh" 2>/dev/null
    . "$T/t8/bin/lib/cost-live.sh"
    cost_live_on
    echo "push_s=${COST_LIVE_PUSH_S:-unset}"
    sleep() { :; }
    _cl_now() { echo $(( 1000 + 10 * $(cat "$T/tc8.n" 2>/dev/null || echo 0) )); }
    cost_live_push() { _cl_now >> "$T/pushes"; }
    cost_live_meter "$(cat "$T/p8.pid")" s8 "$T" )
  wait "$(cat "$T/p8.pid")" 2>/dev/null
}
C8=$(c8 '{"fetched_at":1000000,"values":{"lib.cost-live.cost_live_push_s":"120"},"seeded":{}}')
[ "$C8" = push_s=120 ] && ok || bad "C8 the row did not apply: '$C8'"
[ "$(tr '\n' ' ' < "$T/pushes" 2>/dev/null)" = "1120 1240 1360 " ] && ok || bad "C8 pushes at: $(tr '\n' ' ' < "$T/pushes" 2>/dev/null), want 1120 1240 1360"
C8N=$(c8 none)
[ "$C8N" = push_s=unset ] && ok || bad "C8 with no row something set COST_LIVE_PUSH_S: '$C8N'"
[ "$(tr '\n' ' ' < "$T/pushes" 2>/dev/null)" = "1300 " ] && ok || bad "C8 default pushes at: $(tr '\n' ' ' < "$T/pushes" 2>/dev/null), want 1300"

# =============================================================================
# C9 — the tripwire hook in the meter
# =============================================================================
mk_tree "$T/t9" "echo '10|2|0|0|1.25|claude-fable-5-1|1|1|'"
c9() { # c9 <out> <tw mode: trip|never> <pid> -> meter pid in $T/m9.pid
  rm -f "$T/tw.args" "$T/tw.n"
  ( unset HARNESS_TEST_SANDBOX; export OUT="$1" HARNESS_TICKET=BH-9 COST_LIVE_POLL_S=1 TWMODE="$2"
    . "$T/t9/bin/lib/cost-live.sh"
    cost_live_push() { :; }
    tw_check_build() {
      echo "$*" >> "$T/tw.args"
      [ "$TWMODE" = trip ] || return 1
      local n; n=$(( $(cat "$T/tw.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/tw.n"
      [ "$n" -ge 2 ] || return 1
      printf 'trip\tspend\tusd=900 expected=100 mult=5\n'; return 0
    }
    cost_live_meter "$3" s9 "$T" ) & echo $! > "$T/m9.pid"
}
mkdir -p "$T/builds/freeproj-BH-9-1"; O9="$T/builds/freeproj-BH-9-1/execute.out"; rm -f "$O9.tripwire"
sleep 60 & P9=$!
c9 "$O9" trip "$P9"; M9=$(cat "$T/m9.pid")
wait_until 100 eval '! kill -0 "$M9" 2>/dev/null' && ok || { bad "C9 the meter did not return within 10 s of the trip"; kill "$M9" 2>/dev/null; }
wait_until 20 eval '! kill -0 "$P9" 2>/dev/null' && ok || { bad "C9 the session pid is still alive after the trip"; kill "$P9" 2>/dev/null; }
wait "$P9" 2>/dev/null
read -r TW1 TWREST < "$O9.tripwire" 2>/dev/null || TW1=""
[ "$TW1" = spend ] && ok || bad "C9 \$OUT.tripwire first field '$TW1', want spend: $(cat "$O9.tripwire" 2>/dev/null)"
[ "${TWREST:-}" = "usd=900 expected=100 mult=5" ] && ok || bad "C9 marker detail '${TWREST:-}'"
[ "$(head -1 "$T/tw.args" 2>/dev/null)" = "freeproj BH-9 $T/builds/freeproj-BH-9-1 1.25" ] && ok || bad "C9 tw_check_build argv: $(head -1 "$T/tw.args" 2>/dev/null)"
# negative: not a build outfile -> never asked, no marker
mkdir -p "$T/misc"; sleep 3 & P9B=$!
c9 "$T/misc/out.txt" trip "$P9B"; M9B=$(cat "$T/m9.pid")
wait_until 100 eval '! kill -0 "$M9B" 2>/dev/null' || kill "$M9B" 2>/dev/null
wait "$P9B" 2>/dev/null
[ -e "$T/tw.args" ] && bad "C9 tw_check_build was called for a non-build outfile" || ok
[ -e "$T/misc/out.txt.tripwire" ] && bad "C9 a marker was written for a non-build outfile" || ok
# negative: the contract's never-trip answer -> no marker, the session lives on
rm -f "$O9.tripwire"; sleep 60 & P9C=$!
c9 "$O9" never "$P9C"; M9C=$(cat "$T/m9.pid")
n9() { local n; n=$(grep -c . "$T/tw.args" 2>/dev/null); [ "${n:-0}" -ge 3 ]; }
wait_until 100 n9 && ok || bad "C9 never-trip: tw_check_build asked $(grep -c . "$T/tw.args" 2>/dev/null) times in 10 s, want 3"
kill -0 "$P9C" 2>/dev/null && ok || bad "C9 never-trip: the session was killed"
[ -e "$O9.tripwire" ] && bad "C9 never-trip: a marker was written" || ok
kill "$P9C" 2>/dev/null; wait "$P9C" 2>/dev/null
wait_until 30 eval '! kill -0 "$M9C" 2>/dev/null' || kill "$M9C" 2>/dev/null

# =============================================================================
# C10 — the advisor's spend (BH-3491) is in the meter's number
# =============================================================================
# The default transcript-cost sum is executor-only; an attempt run with
# --advisor (ADV_ATTEMPT set) also has advisor_message iterations, priced by
# --advisor. The live row and the tripwire must see both, or an advisor-heavy
# round runs under the tripwire's radar.
mk_tree "$T/t10" "echo \"\$*\" >> \"$T/tc10.calls\"; case \" \$* \" in *' --advisor '*) echo '5|1|0|0|0.75|advisor-model|1|1|' ;; *) echo '10|2|0|0|1.25|executor-model|1|1|' ;; esac"
c10() { # c10 <adv: 1|''> <pid>
  rm -f "$T/tw.args" "$T/tc10.calls" "$T/push10.log"
  ( unset HARNESS_TEST_SANDBOX; export OUT="$O9" HARNESS_TICKET=BH-9 COST_LIVE_POLL_S=1 COST_LIVE_PUSH_S=1 ADV_ATTEMPT="$1"
    . "$T/t10/bin/lib/cost-live.sh"
    cost_live_push() { printf '%s\n' "$1" >> "$T/push10.log"; }
    tw_check_build() { echo "$*" >> "$T/tw.args"; return 1; }
    cost_live_meter "$2" s10 "$T" ) & echo $! > "$T/m10.pid"
}
sleep 60 & P10=$!
c10 1 "$P10"; M10=$(cat "$T/m10.pid")
n10() { [ -s "$T/tw.args" ] && [ -s "$T/push10.log" ]; }
wait_until 100 n10 && ok || bad "C10 the meter never asked the tripwire / pushed with the advisor on"
kill "$P10" 2>/dev/null; wait "$P10" 2>/dev/null
wait_until 30 eval '! kill -0 "$M10" 2>/dev/null' || kill "$M10" 2>/dev/null
U10=$(head -1 "$T/tw.args" 2>/dev/null | awk '{print $4}')
awk -v u="${U10:-x}" 'BEGIN{exit !(u+0 > 1.9999 && u+0 < 2.0001)}' && ok || bad "C10 tripwire usd '$U10', want executor 1.25 + advisor 0.75 = 2"
C10U=$(head -1 "$T/push10.log" 2>/dev/null | jq -r '.cost_usd' 2>/dev/null)
awk -v u="${C10U:-x}" 'BEGIN{exit !(u+0 > 1.9999 && u+0 < 2.0001)}' && ok || bad "C10 live row cost_usd '$C10U', want 2"
grep -q -- '--advisor' "$T/tc10.calls" 2>/dev/null && ok || bad "C10 the advisor was never priced"
# control: no advisor on this attempt -> the advisor reader never runs, usd is the executor's
sleep 60 & P10B=$!
c10 "" "$P10B"; M10B=$(cat "$T/m10.pid")
wait_until 100 n10 && ok || bad "C10 control: no tripwire ask / push"
kill "$P10B" 2>/dev/null; wait "$P10B" 2>/dev/null
wait_until 30 eval '! kill -0 "$M10B" 2>/dev/null' || kill "$M10B" 2>/dev/null
[ "$(head -1 "$T/tw.args" 2>/dev/null | awk '{print $4}')" = 1.25 ] && ok || bad "C10 control usd: $(head -1 "$T/tw.args" 2>/dev/null)"
grep -q -- '--advisor' "$T/tc10.calls" 2>/dev/null && bad "C10 control: the advisor reader ran with no advisor attempt" || ok

# =============================================================================
# G — the knob manifest
# =============================================================================
ENVS=$(jq -c '[.libs[]|select(.id=="cost-live")|.knobs[].env]|sort' "$T/lanes.json" 2>/dev/null)
[ "$ENVS" = '["COST_LIVE","COST_LIVE_POLL_S","COST_LIVE_PUSH_S","COST_LIVE_STALE_S","COST_ROWS_PUSH_AT_BOUNDARY"]' ] \
  && ok || bad "G cost-live knobs: $ENVS"
for e in COST_LIVE COST_LIVE_POLL_S COST_LIVE_PUSH_S COST_LIVE_STALE_S COST_ROWS_PUSH_AT_BOUNDARY; do
  [ "$(grep -v '^[[:space:]]*#' "$LIB" | grep -cF -- "\${$e:-")" -gt 0 ] && ok || bad "G $LIB never reads \${$e:-"
done
[ "$(cost_live_stale_s)" = 900 ] && [ "$(COST_LIVE_STALE_S=1200 cost_live_stale_s)" = 1200 ] \
  && [ "$(COST_LIVE_STALE_S=abc cost_live_stale_s)" = 900 ] && ok || bad "G cost_live_stale_s: $(cost_live_stale_s)"

echo "cost-live.bh-3500-test: $PASS passed, $FAIL failed (started $NOW)"
[ "$FAIL" -eq 0 ]
