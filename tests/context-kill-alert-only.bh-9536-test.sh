#!/bin/bash
# tests/context-kill-alert-only.bh-9536-test.sh — the context meter in
# bin/agent-call.sh is ALERT ONLY by default (BH-9536, the operator 2026-11-11).
#
# THE DEFECT. context_meter sent TERM to a session whose context crossed its
# bound. The session's work was lost, the ladder classed it budget_stop and the
# ticket planned again from zero (8 plan sessions in 7 days, for example
# BH-9454). The decision: a tripwire alerts and never stops a build.
#
# HOW. A1-A4, A5a, K and F drive the REAL bin/agent-call.sh against a scratch
# $HARNESS with a fake `claude` on PATH (the tests/context-kill.bh-653-test.sh
# pattern). The fake writes a real-shaped transcript, one entry every 0.2 s, so
# the real bin/transcript-cost.sh reads a session that grows while it runs. The
# fake records a TERM in $CASE/got-term and keeps running, so a TERM can never
# hide behind an early exit. A5b cuts context_meter + ctx_over_alert out of
# bin/agent-call.sh (the tests/context-kill-declared.bh-9124-test.sh pattern)
# to prove the declared bound writes no checkpoint brief in alert mode.
#
# Every case has its own scratch dir: no shared state, no order dependence.
# There are 0 vendor calls: claude, grok and timeout are stubs on PATH.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/context-kill-alert-only.bh-9536-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${CTX_ALERT_SRC:-$DIR/bin/agent-call.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# inst_alert_line <harness-dir> — the sanctioned alert writer (bin/alert-line.sh and
# its closure) plus a no-op beat.sh. ctx_over_alert writes through it.
unset LANE_RUN_ID
inst_alert_line() {
  mkdir -p "$1/bin" "$1/logs"
  scratch_install_closure bin/alert-line.sh "$1" >/dev/null || return 1
  [ -f "$DIR/bin/alert_family.py" ] && cp "$DIR/bin/alert_family.py" "$1/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/beat.sh"; chmod +x "$1/bin/beat.sh" "$1/bin/alert-line.sh"
}
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# The suite sets every knob it needs per case; nothing leaks in from the caller.
unset CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_MODE CONTEXT_KILL_MODE_KILL_STAGES \
      CONTEXT_KILL_ALERT_X CONTEXT_KILL_ALERT_MAX CONTEXT_KILL_CLIFF CONTEXT_KILL_CLIFF_MARGIN \
      CONTEXT_KILL_DECLARED CONTEXT_KILL_DECLARED_UNIT CONTEXT_KILL_DECLARED_LANES JOB_ID

# --- the fixtures, shared read-only -------------------------------------------
mkdir -p "$T/fx"
# The lane registry, composed once from this tree's catalog/lanes.d/ (so the new
# context-kill-mode lib is in it). Without LANE_REGISTRY the first agent-call of
# a run renders catalog/lanes.json on demand, and that first call was measured
# running unmetered (no alert and no kill, on main and on this branch alike).
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/fx/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: lanes-build.sh could not compose the registry"; exit 1; }
# kill-lane: a 100,000 cumulative bound. cliff-lane: a 6,000,000 bound that the
# fixture model's 200,000 cliff lowers to 190,000. decl-lane: no cumulative bound,
# a declared per-call ceiling of 4,000 (each fixture call is 5,000).
cat > "$T/fx/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"kill-lane","stage":"eval","project":"testproj","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"cliff-lane","stage":"eval","project":"cliffproj","ceiling_tokens":6000000,
     "target_tokens":1000,"context_kill_tokens":6000000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"decl-lane","stage":"eval","project":"declproj","ceiling_tokens":4000,
     "target_tokens":1000,"composition":[],"bounds":["[lane:none] test fixture PENDING"]}
  ]
}
EOF
cat > "$T/fx/prices.json" <<'EOF'
{
  "claude-fable-5-1": {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0,"cliff_tokens":200000},
  "claude-opus-5":    {"prompt":0.00001,"completion":0.00002,"cache_read":0,"cache_write":0}
}
EOF

# The fake claude. A TERM is RECORDED and ignored, so the stub always runs to
# the end: "got-term" is the only evidence of a signal, never an early exit.
cat > "$T/fx/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$CASE/child.pid"
trap 'touch "$CASE/got-term"' TERM
PROJ="${STUB_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work}"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-11-11T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
  sleep 0.2
done
printf '{"result":"STUB RESULT KEPT","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$T/fx/grok" <<'EOF'
#!/bin/bash
touch "$CASE/grok-was-called"
echo "GROK ANSWER"
EOF
cat > "$T/fx/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The jobs client stub: job_event records its arguments; nothing is sent.
# readonly -f: agent-call.sh later sources libs that load the real jobs client,
# and that client's job_event would replace the stub (and fail with no worker).
cat > "$T/fx/jobs-client.sh" <<'EOF'
job_event() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$CASE/job-events"; }
readonly -f job_event
EOF
chmod +x "$T/fx/claude" "$T/fx/grok" "$T/fx/timeout"

# new_case <name> — a fresh scratch $HARNESS for one case. Prints its path.
new_case() {
  local c="$T/case-$1"
  scratch_rm "$c" 2>/dev/null || [ ! -e "$c" ] || { echo "FAIL: cannot clear $c" >&2; exit 1; }
  mkdir -p "$c/logs" "$c/locks" "$c/flags" "$c/state/model-routes" "$c/bin" "$c/fakebin" \
           "$c/.claude/projects/-work" "$c/.grok/bin" "$c/noenv"
  cp "$T/fx/claude" "$T/fx/grok" "$T/fx/timeout" "$c/fakebin/"
  cp "$T/fx/grok" "$c/.grok/bin/grok"
  cp "$T/fx/jobs-client.sh" "$c/bin/jobs-client.sh"
  printf '#!/bin/bash\necho subscription\n' > "$c/bin/billing-mode.sh"
  printf '#!/bin/bash\nexit 0\n' > "$c/bin/beat.sh"
  chmod +x "$c/bin/billing-mode.sh" "$c/bin/beat.sh"
  local key
  for key in claude.ladder claude.ladder@testproj claude.ladder@cliffproj claude.ladder@declproj; do
    printf '0\tclaude-fable-5-1\tclaude\n1\tclaude-opus-5\tclaude\n' > "$c/state/model-routes/$key.tsv"
  done
  : > "$c/logs/ALERTS.log"; : > "$c/logs/failovers.log"; : > "$c/logs/cost.csv"
  printf '%s' "$c"
}

# run_call <case-dir> <project> [env assignments...] — one real agent-call.sh run. Echoes the rc.
run_call() {
  local c="$1" proj="$2"; shift 2
  ( export PATH="$c/fakebin:$PATH" HARNESS="$c" HOME="$c" CASE="$c" \
           CONTEXT_BUDGETS="$T/fx/budgets.json" MODEL_PRICES="$T/fx/prices.json" \
           CONTEXT_KILL_POLL_S=1 COST_TRANSCRIPT_ROWS=1 LADDER_TIER2_GROK=1 \
           HARNESS_ENV_DIR="$c/noenv" LANE_REGISTRY="$T/fx/lanes.json"
    unset HARNESS_SECRET JOBS_URL AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET
    env "$@" bash "$SRC" eval "$proj" claude-fable-5-1 60 "$c/out" "hello" >/dev/null 2>&1 )
  echo $?
}
nover() { grep -c 'CONTEXT OVER BOUND' "$1/logs/ALERTS.log" 2>/dev/null; }
cost_row() { grep ',eval,claude,' "$1/logs/cost.csv" 2>/dev/null | tail -1; }

# alert_mode_ok <case> <label> — the shared "alerted, not stopped" assertions.
alert_mode_ok() {
  local c="$1" l="$2"
  [ -f "$c/got-term" ] && bad "$l: the session got a TERM in alert mode" || ok
  [ -f "$c/out.ctxkill" ] && bad "$l: \$OUT.ctxkill was written in alert mode: $(cat "$c/out.ctxkill")" || ok
  grep -q 'STUB RESULT KEPT' "$c/out" 2>/dev/null \
    && ok || bad "$l: \$OUT lost the session's result: $(head -c 300 "$c/out" 2>/dev/null)"
  grep -q '^CONTEXT KILL:' <<<"$(tail -1 "$c/out" 2>/dev/null)" \
    && bad "$l: \$OUT ends with a CONTEXT KILL: truncation marker" || ok
  local row; row=$(cost_row "$c")
  grep -qE 'BUDGET_STOP|context-kill:' <<<"$row" \
    && bad "$l: the cost row note says budget stop or context-kill: $row" || ok
  grep -q 'budget stop is policy' "$c/logs/failovers.log" 2>/dev/null \
    && bad "$l: the ladder classed the session a budget stop" || ok
  grep -q 'budget_stop' "$c/out.class" 2>/dev/null \
    && bad "$l: \$OUT.class says budget_stop: $(cat "$c/out.class")" || ok
  [ -f "$c/grok-was-called" ] && bad "$l: a failover lane ran" || ok
}

# =============================================================================
# A1. 40 x 5,000 = 200,000 against a 100,000 bound (not over 2x), knobs unset.
# =============================================================================
C=$(new_case a1)
RC=$(run_call "$C" testproj STUB_ENTRIES=40)
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC, want 0 (the session ran to its own end)"
alert_mode_ok "$C" A1
N=$(nover "$C")
[ "$N" = 1 ] && ok || bad "A1: want exactly 1 CONTEXT OVER BOUND line, found ${N:-0}: $(cat "$C/logs/ALERTS.log")"
AL=$(grep 'CONTEXT OVER BOUND' "$C/logs/ALERTS.log" 2>/dev/null | head -1)
for f in 'eval/testproj' 'ticket=' 'model=claude-fable-5-1' 'session=[0-9a-f-]\{8,\}' 'rule=cumulative' \
         'bound=100000' 'total=[0-9]\{6\}' 'calls=[0-9]\{2\}' 'level=1x' 'the session continues'; do
  grep -q -- "$f" <<<"$AL" && ok || bad "A1: the alert line lacks '$f': $AL"
done
grep -q 'CONTEXT KILL' "$C/logs/ALERTS.log" && bad "A1: a CONTEXT KILL line was written in alert mode" || ok
SID=$(sed -n 's/.*session=\([0-9a-f-]*\).*/\1/p' <<<"$AL")
E=$(grep -c '"usage"' "$C/.claude/projects/-work/$SID.jsonl" 2>/dev/null)
[ "$E" = 40 ] && ok || bad "A1: the transcript has ${E:-0} entries, want all 40 (the session ran to its end)"

# =============================================================================
# A2. 60 x 5,000 = 300,000: over 1x and over 2x (2x is crossed at entry 41, 4 s
# before the stub ends, so a 1 s poll cannot miss it). A2b: the cap knob at 1.
# =============================================================================
C=$(new_case a2)
RC=$(run_call "$C" testproj STUB_ENTRIES=60)
[ "$RC" = 0 ] && ok || bad "A2: rc=$RC, want 0"
alert_mode_ok "$C" A2
N=$(nover "$C")
[ "$N" = 2 ] && ok || bad "A2: want exactly 2 CONTEXT OVER BOUND lines, found ${N:-0}: $(cat "$C/logs/ALERTS.log")"
[ "$(grep 'CONTEXT OVER BOUND' "$C/logs/ALERTS.log" | grep -c 'level=1x')" = 1 ] \
  && ok || bad "A2: no single level=1x line"
[ "$(grep 'CONTEXT OVER BOUND' "$C/logs/ALERTS.log" | grep -c 'level=2x')" = 1 ] \
  && ok || bad "A2: no single level=2x line"

C=$(new_case a2b)
RC=$(run_call "$C" testproj STUB_ENTRIES=60 CONTEXT_KILL_ALERT_MAX=1)
[ "$RC" = 0 ] && ok || bad "A2b: rc=$RC, want 0"
N=$(nover "$C")
[ "$N" = 1 ] && ok || bad "A2b: CONTEXT_KILL_ALERT_MAX=1 gave ${N:-0} lines, want 1"

# =============================================================================
# A3. kill mode: the old stop. Global, per stage, and a near-miss stage list.
# =============================================================================
kill_mode_ok() { # kill_mode_ok <case> <label> <rc>
  local c="$1" l="$2" rc="$3"
  [ "$rc" != 0 ] && ok || bad "$l: a killed session reported rc=0"
  [ -f "$c/got-term" ] && ok || bad "$l: kill mode sent no TERM"
  [ -f "$c/out.ctxkill" ] && ok || bad "$l: kill mode wrote no \$OUT.ctxkill"
  grep -q 'CONTEXT KILL' "$c/logs/ALERTS.log" && ok || bad "$l: no CONTEXT KILL alert"
  { grep -q 'budget_stop' "$c/out.class" 2>/dev/null || grep -q 'budget stop is policy' "$c/logs/failovers.log"; } \
    && ok || bad "$l: the kill was not classed budget_stop ($(cat "$c/out.class" 2>/dev/null))"
  [ "$(nover "$c")" = 0 ] && ok || bad "$l: kill mode also wrote a CONTEXT OVER BOUND line (it says the session continues)"
}
C=$(new_case a3); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE=kill)
kill_mode_ok "$C" "A3 mode=kill" "$RC"
C=$(new_case a3s); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE=alert CONTEXT_KILL_MODE_KILL_STAGES=plan,eval)
kill_mode_ok "$C" "A3 kill stages plan,eval" "$RC"
C=$(new_case a3all); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE_KILL_STAGES=all)
kill_mode_ok "$C" "A3 kill stages all" "$RC"
C=$(new_case a3near); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE_KILL_STAGES="evalx other-stage")
[ "$RC" = 0 ] && ok || bad "A3 near miss: rc=$RC, want 0 (eval is not in 'evalx other-stage')"
alert_mode_ok "$C" "A3 near miss"
[ "$(nover "$C")" = 1 ] && ok || bad "A3 near miss: want 1 alert line"

# =============================================================================
# A4. The meter cannot read the session: no alert, no kill, one UNMETERED line.
# =============================================================================
C=$(new_case a4)
RC=$(run_call "$C" testproj STUB_ENTRIES=40 STUB_TRANSCRIPT_DIR="$C/elsewhere/-work")
[ "$RC" = 0 ] && ok || bad "A4: rc=$RC, want 0"
[ -f "$C/got-term" ] && bad "A4: an unreadable session got a TERM" || ok
[ "$(nover "$C")" = 0 ] && ok || bad "A4: an unreadable session alerted"
grep -q 'running UNMETERED' "$C/logs/claude-cost.log" 2>/dev/null \
  && ok || bad "A4: no 'running UNMETERED' line in claude-cost.log"

# =============================================================================
# A5a. The cliff bound: 6,000,000 lowered to 190,000. 60 x 5,000 = 300,000: the
# bound is crossed at entry 39, 4 s before the stub ends (40 entries was a race).
# =============================================================================
C=$(new_case a5a)
RC=$(run_call "$C" cliffproj STUB_ENTRIES=60 CONTEXT_KILL_CLIFF=1)
[ "$RC" = 0 ] && ok || bad "A5a: rc=$RC, want 0"
alert_mode_ok "$C" A5a
[ -f "$C/out.cliffcap" ] && ok || bad "A5a: no \$OUT.cliffcap — the fixture did not take the cliff path"
AL=$(grep 'CONTEXT OVER BOUND' "$C/logs/ALERTS.log" 2>/dev/null)
[ "$(nover "$C")" = 1 ] && ok || bad "A5a: want 1 alert line, got: $AL"
grep -q 'rule=cliff' <<<"$AL" && grep -q 'bound=190000' <<<"$AL" \
  && ok || bad "A5a: the line does not say rule=cliff bound=190000: $AL"
grep -q 'CLIFF-AVOIDED' "$C/logs/ALERTS.log" "$C/logs/failovers.log" \
  && bad "A5a: a CLIFF-AVOIDED stop line was written in alert mode" || ok

# A5a'. The declared bound, real run: each 5,000-token call is over decl-lane's 4,000.
C=$(new_case a5d)
RC=$(run_call "$C" declproj STUB_ENTRIES=20 CONTEXT_KILL_DECLARED_LANES=eval)
[ "$RC" = 0 ] && ok || bad "A5 declared: rc=$RC, want 0"
alert_mode_ok "$C" "A5 declared"
AL=$(grep 'CONTEXT OVER BOUND' "$C/logs/ALERTS.log" 2>/dev/null)
[ "$(nover "$C")" = 1 ] && grep -q 'rule=declared' <<<"$AL" && grep -q 'bound=4000' <<<"$AL" \
  && ok || bad "A5 declared: want 1 rule=declared bound=4000 line, got: $AL"
# ...and the same lane in kill mode stops, so the fixture really arms the declared rule.
C=$(new_case a5dk)
RC=$(run_call "$C" declproj STUB_ENTRIES=20 CONTEXT_KILL_DECLARED_LANES=eval CONTEXT_KILL_MODE=kill)
[ -f "$C/got-term" ] && [ -f "$C/out.ctxkill" ] && grep -q 'rule=declared' "$C/out.ctxkill" \
  && ok || bad "A5 declared kill: the fixture lane was not stopped in kill mode (rc=$RC)"

# A5b. The declared bound on execute in a build dir: no checkpoint brief in
# alert mode, and a brief in kill mode (so the assertion is not vacuous).
BLD="$T/b5/builds/someproj-BH-1-202611110000"
mkdir -p "$T/b5/logs" "$T/b5/bin/lib" "$T/b5/work" "$BLD"
scratch_install_closure bin/lib/execute-checkpoint-brief.sh "$T/b5" >/dev/null \
  && [ -r "$T/b5/bin/lib/execute-checkpoint-brief.sh" ] || bad "A5b: cannot install execute-checkpoint-brief.sh"
git -C "$T/b5/work" init -q 2>/dev/null
printf 'base\n' > "$T/b5/work/README.md"
git -C "$T/b5/work" add README.md && git -C "$T/b5/work" -c user.email=t@t -c user.name=t commit -qm base
printf '# Plan\n\n## Acceptance tests\n\n- M1. fixture.\n' > "$BLD/plan.md"
git -C "$T/b5/work" rev-parse HEAD > "$BLD/collision-base"
cat > "$T/b5/bin/fake-tc" <<'EOF'
#!/bin/bash
n=$(cat "$POLLF" 2>/dev/null || echo 0); echo $((n + 1)) > "$POLLF"
printf '%s\n' "$FAKE_LINE"
EOF
chmod +x "$T/b5/bin/fake-tc"
inst_alert_line "$T/b5" || bad "A5b: cannot install alert-line.sh"
FNS=$(sed -n '/^_ctx_declared_row()/,/^}/p; /^context_meter()/,/^}/p; /^ctx_kill_alert()/,/^}/p; /^ctx_over_alert()/,/^}/p' "$SRC")
meter5b() { # meter5b <mode> — 2 polls of a 500,001-token call on execute (ceiling 4,000 via fixture)
  rm -f "$T/b5/polls" "$T/b5/terms" "$BLD/checkpoint-brief.md" "$BLD"/*.ctxkill "$T/b5/logs/ALERTS.log"
  (
    eval "$FNS"
    HARNESS="$T/b5"; PROJECT=someproj; STAGE=execute; runner=claude; ALERTS="$T/b5/logs/ALERTS.log"
    OUT="$BLD/execute.out"; CONTEXT_KILL_MODE="$1"; CONTEXT_KILL_DECLARED_LANES=execute
    CONTEXT_BUDGETS="$T/b5/budgets.json"
    _CTX_TCB="$T/b5/bin/fake-tc"; POLLF="$T/b5/polls"; export POLLF
    FAKE_LINE="10|10|1000|0|0.100000|claude-fixture|3|1||500001"; export FAKE_LINE
    STAMP() { printf '2026-11-11T00:00:00Z'; }
    sleep() { :; }
    kill() {
      case "$1" in
        -0) [ "$(cat "$POLLF" 2>/dev/null || echo 0)" -lt 2 ] ;;
        -TERM) echo TERM >> "$T/b5/terms" ;;
      esac
    }
    context_meter 4242 sid-fixture "" "$T/b5/work"
  )
}
printf '{"lanes":[{"lane":"x","stage":"execute","ceiling_tokens":4000}]}\n' > "$T/b5/budgets.json"
meter5b alert
[ -f "$T/b5/terms" ] && bad "A5b: alert mode sent a TERM on the declared bound" || ok
[ -f "$BLD/checkpoint-brief.md" ] && bad "A5b: alert mode wrote checkpoint-brief.md" || ok
grep -q 'rule=declared' "$T/b5/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "A5b: no rule=declared alert line: $(cat "$T/b5/logs/ALERTS.log" 2>/dev/null)"
meter5b kill
[ -f "$T/b5/terms" ] && [ -s "$BLD/checkpoint-brief.md" ] \
  && ok || bad "A5b: kill mode wrote no brief or sent no TERM — the alert-mode negative is vacuous"

# =============================================================================
# K. The switches still turn the meter off, in both modes. A bogus mode is alert.
# =============================================================================
for m in alert kill; do
  C=$(new_case "k0-$m"); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL=0 CONTEXT_KILL_MODE=$m)
  [ "$RC" = 0 ] && [ ! -f "$C/got-term" ] && [ "$(nover "$C")" = 0 ] && ! grep -q 'CONTEXT KILL' "$C/logs/ALERTS.log" \
    && ok || bad "K: CONTEXT_KILL=0 (mode $m) did not turn the meter off (rc=$RC)"
  C=$(new_case "kf-$m"); touch "$C/flags/context-kill-off"
  RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE=$m)
  [ "$RC" = 0 ] && [ ! -f "$C/got-term" ] && [ "$(nover "$C")" = 0 ] && ! grep -q 'CONTEXT KILL' "$C/logs/ALERTS.log" \
    && ok || bad "K: flags/context-kill-off (mode $m) did not turn the meter off (rc=$RC)"
done
C=$(new_case kbogus); RC=$(run_call "$C" testproj STUB_ENTRIES=40 CONTEXT_KILL_MODE=bogus)
[ "$RC" = 0 ] && ok || bad "K: CONTEXT_KILL_MODE=bogus: rc=$RC, want 0 (alert)"
alert_mode_ok "$C" "K bogus"
[ "$(nover "$C")" = 1 ] && ok || bad "K: CONTEXT_KILL_MODE=bogus did not alert"

# =============================================================================
# F. One job_event per alert line, verdict CONTEXT_OVER.
# =============================================================================
C=$(new_case f)
RC=$(run_call "$C" testproj STUB_ENTRIES=60 JOB_ID=job-fixture-9536)
N=$(nover "$C")
JE=$(grep -c '|CONTEXT_OVER|' "$C/job-events" 2>/dev/null)
[ "$N" = 2 ] && [ "$JE" = 2 ] \
  && ok || bad "F: want 2 alert lines and 2 CONTEXT_OVER job events, got ${N:-0} and ${JE:-0}: $(cat "$C/job-events" 2>/dev/null)"
grep -qv '^job-fixture-9536|eval|CONTEXT_OVER|rule=cumulative bound=100000 ' <<<"$(grep '|CONTEXT_OVER|' "$C/job-events" 2>/dev/null)" \
  && bad "F: a job event has the wrong shape: $(cat "$C/job-events")" || ok
grep -q '|BUDGET_STOP|' "$C/job-events" 2>/dev/null && bad "F: an alert wrote a BUDGET_STOP job event" || ok

# =============================================================================
# R. The knob file is registered: the composed registry carries the lib and its 4 knobs.
# =============================================================================
KF="$DIR/catalog/lanes.d/_lib.context-kill-mode.json"
[ -r "$KF" ] && ok || bad "R: no $KF"
jq -e '[.libs[] | select(.id == "context-kill-mode") | .knobs[].env] == ["CONTEXT_KILL_MODE","CONTEXT_KILL_MODE_KILL_STAGES","CONTEXT_KILL_ALERT_X","CONTEXT_KILL_ALERT_MAX"]' \
  "$T/fx/lanes.json" >/dev/null 2>&1 && ok || bad "R: the composed registry lacks the context-kill-mode lib or its 4 knobs"

# =============================================================================
# V. The mode and level knobs, on the cut meter (no wall clock): one poll per
#    case at a fixed total against a 100,000 cumulative bound.
# =============================================================================
mkdir -p "$T/v/logs" "$T/v/bin"
cat > "$T/v/bin/fake-tc" <<'EOF'
#!/bin/bash
n=$(cat "$POLLF" 2>/dev/null || echo 0); echo $((n + 1)) > "$POLLF"
printf '%s\n' "$FAKE_LINE"
EOF
chmod +x "$T/v/bin/fake-tc"
inst_alert_line "$T/v" || bad "V: cannot install alert-line.sh"
printf '{"lanes":[]}\n' > "$T/v/budgets.json"
# meterv <total> [env assignments...] — prints "<alert lines> <TERMs> <levels>"
meterv() {
  local tot="$1"; shift
  rm -f "$T/v/polls" "$T/v/terms" "$T/v/logs/ALERTS.log" "$T/v/out.ctxkill"
  (
    eval "$FNS"
    HARNESS="$T/v"; PROJECT=vproj; STAGE=plan; runner=claude; ALERTS="$T/v/logs/ALERTS.log"
    OUT="$T/v/out"; CONTEXT_BUDGETS="$T/v/budgets.json"; CONTEXT_KILL_DECLARED=0
    _CTX_TCB="$T/v/bin/fake-tc"; POLLF="$T/v/polls"; export POLLF
    FAKE_LINE="$tot|10|0|0|0.100000|claude-fixture|7|1||5000"; export FAKE_LINE
    STAMP() { printf '2026-11-11T00:00:00Z'; }
    sleep() { :; }
    kill() {
      case "$1" in
        -0) [ "$(cat "$POLLF" 2>/dev/null || echo 0)" -lt 1 ] ;;
        -TERM) echo TERM >> "$T/v/terms" ;;
      esac
    }
    for a in "$@"; do export "${a?}"; done
    context_meter 4242 sid-v 100000 "$T/v" "" "" 0 0 claude-fixture-model
  )
  local n=0 t=0 lv=""
  [ -f "$T/v/logs/ALERTS.log" ] && n=$(grep -c 'CONTEXT OVER BOUND' "$T/v/logs/ALERTS.log")
  [ -f "$T/v/terms" ] && t=$(wc -l < "$T/v/terms" | tr -d ' ')
  [ -f "$T/v/logs/ALERTS.log" ] && lv=$(sed -n 's/.* level=\([0-9]*x\).*/\1/p' "$T/v/logs/ALERTS.log" | tr '\n' ',')
  echo "$n $t $lv"
}
vcase() { # vcase <label> <want> <total> [env...]
  local l="$1" want="$2" got; shift 2
  got=$(meterv "$@")
  [ "$got" = "$want" ] && ok || bad "V $l: got '$got', want '$want'"
}
vcase "equal is not over"            "0 0 "        100000
vcase "cap+1 fires 1x"               "1 0 1x,"     100001
vcase "2x exactly is 1x only"        "1 0 1x,"     200000
vcase "2x+1 fires both"              "2 0 1x,2x,"  200001
vcase "X=3: 250K is 1x only"         "1 0 1x,"     250000 CONTEXT_KILL_ALERT_X=3
vcase "X=3: 300001 fires 3x"         "2 0 1x,3x,"  300001 CONTEXT_KILL_ALERT_X=3
vcase "X=bogus is 2"                 "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_X=bogus
vcase "X=1 (under min) is 2"         "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_X=1
vcase "X=101 (over max) is 2"        "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_X=101
vcase "MAX=1 caps at 1"              "1 0 1x,"     200001 CONTEXT_KILL_ALERT_MAX=1
vcase "MAX=0 (under min) is 2"       "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_MAX=0
vcase "MAX=x is 2"                   "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_MAX=x
vcase "MAX=11 (over max) is 2"       "2 0 1x,2x,"  200001 CONTEXT_KILL_ALERT_MAX=11
vcase "mode KILL kills"              "0 1 "        100001 CONTEXT_KILL_MODE=KILL
vcase "mode empty is alert"          "1 0 1x,"     100001 CONTEXT_KILL_MODE=
vcase "stages plan,execute kills"    "0 1 "        100001 CONTEXT_KILL_MODE_KILL_STAGES=plan,execute
vcase "stages plan-x is alert"       "1 0 1x,"     100001 CONTEXT_KILL_MODE_KILL_STAGES=plan-x
grep -q 'model=claude-fixture-model' <<<"$(meterv 100001 >/dev/null; cat "$T/v/logs/ALERTS.log" 2>/dev/null)" \
  && ok || bad "V: the alert line does not carry the model passed as the 9th argument"

# L: no lane-alert.sh beside the script and none in $HARNESS/bin. The line goes
# through bin/alert-line.sh (the alert-writers ratchet: no raw ALERTS append).
L="$T/l"; inst_alert_line "$L" || bad "L: cannot install alert-line.sh"
LRC=$( ( HARNESS="$L" STAGE=plan PROJECT=lproj ALERTS="$L/logs/ALERTS.log"
         STAMP() { date -u '+%F %TZ'; }
         eval "$(sed -n '/^ctx_over_alert()/,/^}/p' "$SRC")"
         BASH_ARGV0="$L/bin/agent-call.sh"
         ctx_over_alert m-l cumulative 100 201 7 sid-l 1 ) >/dev/null 2>&1; echo $?)
[ "$LRC" = 0 ] && ok || bad "L: ctx_over_alert rc=$LRC with no lane-alert, want 0"
[ "$(grep -c 'CONTEXT OVER BOUND (alert only): plan/lproj .*session=sid-l' "$L/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L: no lane-alert: want 1 line through alert-line.sh, got: $(cat "$L/logs/ALERTS.log" 2>/dev/null)"

echo "context-kill-alert-only: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
