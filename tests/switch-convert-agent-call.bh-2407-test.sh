#!/bin/bash
# tests/switch-convert-agent-call.bh-2407-test.sh — the agent-call hot path and
# call-guard kill switches read through lane_switch (BH-2432, BH-2407.1).
#
# Five switches moved from a bare `[ -f flags/<name> ]` to
# `lane_switch <name> file`: cliff-route-off, cliff-refuse-off,
# context-kill-off and agent-call-ledger-off in bin/agent-call.sh, and
# call-guard-off in bin/lib/call-guard.sh. For each one, driven through the
# real code (agent-call.sh with fake CLIs, or the real call-guard lib):
#   (i)   a row switch.<name>=1 and no file turns the thing off;
#   (ii)  a row switch.<name>=0 beats a file on the box: the thing runs, and
#         logs/lane-gate.log names the ignored file exactly once;
#   (iii) no row and the file: off, exactly as before.
# Every case asserts the settings row was fetched and that NOTHING asked
# /api/flags (file mode never reconciles pause_flags).
#   B  sourcing call-guard.sh on its own loads nothing else: lane-switch.sh
#      (and lane-gate.sh) arrive only when call_guard_enabled runs;
#   N1 a box with no bin/lib/lane-switch.sh still honours the file (the shims
#      in agent-call.sh and in call-guard.sh);
#   N2 LANE_GATE_DISABLE=1 turns the rows off, not the switch: row=0 plus the
#      file is still off, and nothing is asked of the worker;
#   S0 no bare read of the five names is left in bin/ or fly/.
# Run from anywhere: tests/switch-convert-agent-call.bh-2407-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-9536: the meter default is alert; this suite pins the kill mode
export CONTEXT_KILL_MODE=kill
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export ENDPOINT_OPENROUTER=https://openrouter.ai
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LANE_GATE_DISABLE AGENT_CALL_TICKET COST_KEY HARNESS_TICKET JOB_ID
export JOBS_BOX=testbox CALLS="$T/calls" ROWS_FILE="$T/rows.json"

# The stub worker, at the path _lg_ensure_client (and agent-call.sh) sources.
# Every request lands in $CALLS, so "no /api/flags" is counted, not assumed;
# /api/settings answers the rows in $ROWS_FILE. flag_sync/flag_active keep the
# real bin/lib/jobs/flags.sh contract (GET /api/flags/<name>, then the file), so
# a switch read in flag mode instead of file mode shows up as a request.
cat > "$T/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
flag_sync() { _jobs_req GET "/api/flags/${1:-}" >/dev/null; }
flag_active() { flag_sync "${1:-}" || true; [ -f "$HARNESS/flags/${1:-}" ]; }
SH

mkh() { # mkh <harness> — a scratch harness with the stub worker and the usual shims
  mkdir -p "$1/bin" "$1/fakebin" "$1/flags" "$1/locks" "$1/logs" "$1/state"
  cp "$T/stub-jobs-client.sh" "$1/bin/jobs-client.sh"
  printf '#!/bin/bash\necho subscription\n' > "$1/bin/billing-mode.sh"
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/beat.sh"
  printf '#!/bin/bash\necho "test rules"\n' > "$1/bin/sync-agent-rules.sh"
  cat > "$1/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
  chmod +x "$1/bin/"*.sh "$1/fakebin/timeout"
}

# setup <harness> <switch> <row 1|0|-> <file 1|0> — one case's world: the rows
# table, the flag file, and no cache, throttle state or log left from the last.
setup() {
  local h="$1" name="$2" row="$3" file="$4"
  scratch_rm "$h/state/lane-gate"; scratch_rm "$h/state/settings-cache.json"; scratch_rm "$h/logs/lane-gate.log"
  rm -f "${h:?}/flags/"*
  : > "$CALLS"
  if [ "$row" = - ]; then echo '[]' > "$ROWS_FILE"
  else jq -nc --arg k "switch.$name" --arg v "$row" '[{key:$k,value:$v,actor:"api"}]' > "$ROWS_FILE"; fi
  [ "$file" = 1 ] && touch "$h/flags/$name"
  return 0
}
countl() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
# wire <label> <harness> <switch> <row> — what every case asserts on the worker
# traffic and the ignored-file line.
wire() {
  local label="$1" h="$2" name="$3" row="$4"
  eq "$label no /api/flags request" "$(countl '/api/flags' "$CALLS")" 0
  [ "$(countl 'GET /api/settings' "$CALLS")" -ge 1 ] && ok \
    || bad "$label the settings rows were never fetched: $(paste -sd, "$CALLS")"
  if [ "$row" = 0 ] && [ -f "$h/flags/$name" ]; then
    eq "$label one lane-gate.log line names the ignored file" \
      "$(countl "switch $name: row says 0 (switch.$name), flags/$name ignored" "$h/logs/lane-gate.log")" 1
  fi
}

# ── R1 cliff-route-off / R2 cliff-refuse-off: the runner-cliff / lane-day-cap
# shape. Ten rc-0 rows past grok's 200K cliff; otherproj's lane routes, and
# testproj's lane routes AND refuses (claude costs more than a doubled grok).
HR="$T/rc"; mkh "$HR"
mrs_fixture "$HR" testproj otherproj
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
               "cache_write": null, "cliff_tokens": 200000},
  "claude-opus-5": {"prompt": 0.000015, "completion": 0.000075,
                    "cache_read": 0.0000015, "cache_write": 0.00001875}
}}
EOF
cat > "$T/cb.json" <<'EOF'
{"lanes": [
  {"lane":"refuse-fixture","stage":"eval","project":"testproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true,"cliff_refuse":true},
  {"lane":"route-only","stage":"eval","project":"otherproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true}
]}
EOF
cat > "$HR/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$HR/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
printf '{"result":"claude answered","session_id":"s-fake"}\n'
EOF
cat > "$HR/fakebin/codex" <<'EOF'
#!/bin/bash
echo codex >> "$ORDER_SINK"
echo "codex answered"
EOF
chmod +x "$HR/fakebin/"*
HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
ledger() { # ledger <harness> — a fresh cost.csv with ten over-cliff rows per project
  local h="$1" p i r n
  printf '%s\n' "$HDR" > "$h/logs/cost.csv"
  for p in testproj otherproj; do
    i=0
    while [ "$i" -lt 10 ]; do
      r="2026-09-18T00:00:00Z,box,$p,eval,claude,claude-opus-5,0,10,676000,100,0,0,0.10,subscription,fp,acct,sess,transcript,,,,,"
      n=$(awk -F, '{print NF}' <<<"$r"); while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
      printf '%s\n' "$r" >> "$h/logs/cost.csv"; i=$((i+1))
    done
  done
}
drive_rc() { # drive_rc <harness> <agent-call.sh> <project> ; echoes agent-call's rc
  local h="$1" ac="$2" pj="$3"
  ledger "$h"; : > "$T/order"; : > "$h/logs/failovers.log"; : > "$h/logs/ALERTS.log"
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY \
          RUNNER_CLIFF_ROUTE LADDER_CLIFF_REFUSE
    export HOME="$h" HARNESS="$h" PATH="$h/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$T/cb.json" \
           ORDER_SINK="$T/order" LADDER_BACKOFF_SECS=0 \
           RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=claude
    bash "$ac" eval "$pj" claude-opus-5 60 "$h/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
order() { paste -sd, "$T/order"; }

echo "--- R1 cliff-route-off (agent-call.sh, route-only lane)"
# Control: no row, no file — the lane routes, grok is never called.
setup "$HR" cliff-route-off - 0
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" otherproj)
eq "R1 control: the lane routes past grok" "$(order)" claude
setup "$HR" cliff-route-off 1 0
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" otherproj)
eq "R1(i) row=1, no file: routing is off and grok runs" "$(order)" grok
wire "R1(i)" "$HR" cliff-route-off 1
setup "$HR" cliff-route-off 0 1
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" otherproj)
eq "R1(ii) row=0 beats the file: the lane routes" "$(order)" claude
wire "R1(ii)" "$HR" cliff-route-off 0
setup "$HR" cliff-route-off - 1
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" otherproj)
eq "R1(iii) no row, file: routing is off, as before" "$(order)" grok
wire "R1(iii)" "$HR" cliff-route-off -

echo "--- R2 cliff-refuse-off (agent-call.sh, refusing lane)"
setup "$HR" cliff-refuse-off - 0
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" testproj)
eq "R2 control: the lane refuses (rc 79)" "$RC" 79
setup "$HR" cliff-refuse-off 1 0
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" testproj)
eq "R2(i) row=1, no file: no refusal, rc" "$RC" 0
eq "R2(i) the rung below serves" "$(order)" claude
eq "R2(i) no CLIFF REFUSE line" "$(countl 'CLIFF REFUSE' "$HR/logs/failovers.log")" 0
wire "R2(i)" "$HR" cliff-refuse-off 1
setup "$HR" cliff-refuse-off 0 1
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" testproj)
eq "R2(ii) row=0 beats the file: refused, rc" "$RC" 79
eq "R2(ii) nothing was called" "$(order)" ""
[ "$(countl 'CLIFF REFUSE' "$HR/logs/failovers.log")" -ge 1 ] && ok \
  || bad "R2(ii) the refusal must be declared in failovers.log"
wire "R2(ii)" "$HR" cliff-refuse-off 0
setup "$HR" cliff-refuse-off - 1
RC=$(drive_rc "$HR" "$DIR/bin/agent-call.sh" testproj)
eq "R2(iii) no row, file: no refusal, as before, rc" "$RC" 0
eq "R2(iii) the rung below serves" "$(order)" claude
wire "R2(iii)" "$HR" cliff-refuse-off -

# ── R3 context-kill-off: the context-kill.bh-653 case 5 shape. The lane's
# ceiling is 100000; the fake claude grows its transcript 5000 tokens a step.
echo "--- R3 context-kill-off (agent-call.sh, metered session)"
HK="$T/ck"; mkh "$HK"
cat > "$T/budgets.json" <<'EOF'
{"_units": "input_toks + cache_read",
 "lanes": [
  {"lane":"kill-lane","stage":"eval","project":"testproj","ceiling_tokens":200000,
   "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
   "bounds":["[lane:context_kill] test fixture PENDING"]}
 ]}
EOF
cat > "$HK/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
PROJ="$HOME/.claude/projects/-work"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-17T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
  sleep 0.2
done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
printf '#!/bin/bash\necho "GROK ANSWER"\n' > "$HK/fakebin/grok"
chmod +x "$HK/fakebin/"*
drive_ck() { # drive_ck ; echoes agent-call's rc, $T/ck.out is the answer
  rm -f "$T/ck.out" "$T/ck.out.json" "$T/ck.out.err" "$T/ck.out.ctxkill"
  : > "$HK/logs/ALERTS.log"
  ( unset CONTEXT_KILL CONTEXT_KILL_TOKENS
    export PATH="$HK/fakebin:$PATH" HARNESS="$HK" HOME="$HK" \
           CONTEXT_BUDGETS="$T/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 LADDER_TIER2_GROK=1 STUB_ENTRIES=30
    bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$T/ck.out" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
killed() { [ -f "$T/ck.out.ctxkill" ] && echo killed || echo ran; }
setup "$HK" context-kill-off - 0
RC=$(drive_ck)
eq "R3 control: the session is killed at its ceiling" "$(killed)" killed
setup "$HK" context-kill-off 1 0
RC=$(drive_ck)
eq "R3(i) row=1, no file: no kill" "$(killed)" ran
eq "R3(i) the old foreground path completes" "$RC:$(cat "$T/ck.out" 2>/dev/null)" "0:CLEAN DONE"
wire "R3(i)" "$HK" context-kill-off 1
setup "$HK" context-kill-off 0 1
RC=$(drive_ck)
eq "R3(ii) row=0 beats the file: the kill fires" "$(killed)" killed
wire "R3(ii)" "$HK" context-kill-off 0
setup "$HK" context-kill-off - 1
RC=$(drive_ck)
eq "R3(iii) no row, file: no kill, as before" "$(killed)" ran
eq "R3(iii) the old foreground path completes" "$RC:$(cat "$T/ck.out" 2>/dev/null)" "0:CLEAN DONE"
wire "R3(iii)" "$HK" context-kill-off -

# ── R4 agent-call-ledger-off: the agent-call-choke-guard.bh-1037 case 8 shape.
# Two identical review calls: with the ledger on, the second is a replay.
echo "--- R4 agent-call-ledger-off (agent-call.sh, review replay)"
HL="$T/lg"; mkh "$HL"
mrs_fixture "$HL" testproj
cat > "$HL/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the review text","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
chmod +x "$HL/fakebin/claude"
call_lg() { # call_lg <prompt>
  ( export AGENT_CALL_LEDGER=1 ORDER_SINK="$T/order" PATH="$HL/fakebin:$PATH" HARNESS="$HL" HOME="$HL" \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 \
           AGENT_CALL_RUNNERS= RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK= \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/lg.out" "$1" >/dev/null 2>&1 )
}
twice() { # twice <prompt> ; echoes the vendor calls two identical calls made
  scratch_rm "$HL/state/agent-call-ledger"; : > "$T/order"
  call_lg "$1"; call_lg "$1"
  countl '^claude$' "$T/order"
}
setup "$HL" agent-call-ledger-off - 0
eq "R4 control: the second identical call is replayed" "$(twice "r4 control")" 1
setup "$HL" agent-call-ledger-off 1 0
eq "R4(i) row=1, no file: both calls reach the vendor" "$(twice "r4 row on")" 2
wire "R4(i)" "$HL" agent-call-ledger-off 1
setup "$HL" agent-call-ledger-off 0 1
eq "R4(ii) row=0 beats the file: the second call is replayed" "$(twice "r4 row off")" 1
wire "R4(ii)" "$HL" agent-call-ledger-off 0
setup "$HL" agent-call-ledger-off - 1
eq "R4(iii) no row, file: both calls reach the vendor, as before" "$(twice "r4 legacy")" 2
wire "R4(iii)" "$HL" agent-call-ledger-off -

# ── R5 call-guard-off: the REAL bin/lib/call-guard.sh, sourced on its own the
# way bin/claude-cost.sh sources it, with rows on (the k3 runner pins
# LANE_GATE_DISABLE=1; its 10b re-proves the hatch plus the file).
echo "--- R5 call-guard-off (bin/lib/call-guard.sh)"
HG="$T/cg"; mkh "$HG"
cg() { # cg ; echoes call_guard_enabled review's rc
  env HARNESS="$HG" bash -c '
    unset CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP
    . "$1/bin/lib/call-guard.sh" || exit 9
    call_guard_enabled review; echo $?' _ "$DIR" 2>/dev/null
}
setup "$HG" call-guard-off - 0
eq "R5 control: the guard is enforced for review" "$(cg)" 0
setup "$HG" call-guard-off 1 0
eq "R5(i) row=1, no file: the guard is off" "$(cg)" 1
wire "R5(i)" "$HG" call-guard-off 1
setup "$HG" call-guard-off 0 1
eq "R5(ii) row=0 beats the file: the guard is enforced" "$(cg)" 0
wire "R5(ii)" "$HG" call-guard-off 0
setup "$HG" call-guard-off - 1
eq "R5(iii) no row, file: the guard is off, as before" "$(cg)" 1
wire "R5(iii)" "$HG" call-guard-off -

# ── N1 the no-lib shim: a box whose sync has not landed lane-switch.sh still
# honours the file, and does not route when the file says off.
echo "--- N1 no bin/lib/lane-switch.sh"
HN="$T/nl"; mkh "$HN"
cp -r "$HR/fakebin/." "$HN/fakebin/"
mrs_fixture "$HN" testproj otherproj
mkdir -p "$T/nolib"
cp -r "$DIR/bin" "$T/nolib/"
rm -f "$T/nolib/bin/lib/lane-switch.sh"
# CALL_GUARD=0 on purpose: call_guard_enabled runs before the grok rung and, on
# a box with no lib, defines its own file shim — which would answer for
# agent-call's. With the guard off it returns before loading anything, so only
# agent-call.sh's shim can answer here. N1b is the default path through it.
setup "$HN" cliff-route-off - 0
RC=$(CALL_GUARD=0 drive_rc "$HN" "$T/nolib/bin/agent-call.sh" otherproj)
eq "N1 control: with no lib and no file the lane routes" "$(order)" claude
setup "$HN" cliff-route-off - 1
RC=$(CALL_GUARD=0 drive_rc "$HN" "$T/nolib/bin/agent-call.sh" otherproj)
eq "N1 with no lib the file still turns routing off (agent-call's shim)" "$(order)" grok
setup "$HN" cliff-route-off - 1
RC=$(drive_rc "$HN" "$T/nolib/bin/agent-call.sh" otherproj)
eq "N1b with no lib and the guard on, the file still turns routing off" "$(order)" grok
# N1c call-guard.sh sourced on its own (bin/claude-cost.sh's way) from the same
# no-lib tree: its in-function shim answers what the file answered.
cg_nolib() {
  env HARNESS="$HG" bash -c '
    unset CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP
    . "$1/bin/lib/call-guard.sh" || exit 9
    call_guard_enabled review; echo $?' _ "$T/nolib" 2>/dev/null
}
setup "$HG" call-guard-off - 0
eq "N1c control: with no lib and no file the guard is enforced" "$(cg_nolib)" 0
setup "$HG" call-guard-off - 1
eq "N1c with no lib the file still turns the guard off (call-guard's shim)" "$(cg_nolib)" 1

# ── B the lazy source: call-guard.sh alone defines no lane-gate function; the
# first call_guard_enabled loads lane-switch.sh (and lane-gate.sh through it).
echo "--- B call-guard.sh sources lane-switch.sh lazily"
setup "$HG" call-guard-off - 0
LAZY=$(env HARNESS="$HG" bash -c '
  unset CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP
  . "$1/bin/lib/call-guard.sh" || exit 9
  command -v _lg_settings_refresh >/dev/null 2>&1 && printf before- || printf none-
  command -v lane_switch >/dev/null 2>&1 && printf ls- || printf nols-
  call_guard_enabled review >/dev/null
  command -v _lg_settings_refresh >/dev/null 2>&1 && printf after || printf never' _ "$DIR" 2>/dev/null)
eq "B sourcing alone loads nothing; the first call loads the switch lib" "$LAZY" "none-nols-after"

# ── N2 the hatch: LANE_GATE_DISABLE=1 skips the rows and reads the file, for
# both the call-guard lib and agent-call.sh, with no worker request at all.
echo "--- N2 LANE_GATE_DISABLE=1"
setup "$HG" call-guard-off 0 1
eq "N2 hatch, row=0 plus the file: the guard is off" "$(LANE_GATE_DISABLE=1 cg)" 1
eq "N2 hatch: no /api/flags request" "$(countl '/api/flags' "$CALLS")" 0
eq "N2 hatch: no settings read" "$(countl '/api/settings' "$CALLS")" 0
setup "$HR" cliff-route-off 0 1
RC=$(LANE_GATE_DISABLE=1 drive_rc "$HR" "$DIR/bin/agent-call.sh" otherproj)
eq "N2 hatch, row=0 plus the file: routing is off and grok runs" "$(order)" grok
eq "N2 hatch agent-call: no /api/flags request" "$(countl '/api/flags' "$CALLS")" 0

# ── S0 no bare read of the five names is left. The pattern is the ratchet's own.
echo "--- S0 no bare read left"
BARE_RE=$(sed -n "s/^BARE_RE='\(.*\)'\$/\1/p" "$DIR/tests/switch-ratchet.bh-2320-test.sh")
if [ -z "$BARE_RE" ]; then bad "S0 could not read BARE_RE from tests/switch-ratchet.bh-2320-test.sh"
elif [ ! -d "$DIR/bin" ] || [ ! -d "$DIR/fly" ]; then bad "S0 bin/ or fly/ is missing under $DIR"
else
  LEFT=$(grep -rnoE "$BARE_RE" "$DIR/bin" "$DIR/fly" 2>/dev/null \
    | grep -E 'flags/(cliff-route-off|cliff-refuse-off|context-kill-off|agent-call-ledger-off|call-guard-off)$')
  [ -z "$LEFT" ] && ok || bad "S0 bare reads left: $LEFT"
fi

echo "switch-convert-agent-call: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
