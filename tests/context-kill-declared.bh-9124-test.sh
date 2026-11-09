#!/bin/bash
# tests/context-kill-declared.bh-9124-test.sh — THE DECLARED KILL in
# bin/agent-call.sh context_meter (BH-9124, slice C2 of BH-9064), and the
# `peak` field of bin/transcript-cost.sh --peak that it reads.
#
# THE DEFECT. The meter compared only the cumulative session total with
# context_kill_tokens (53.6M on execute). A lane with no context_kill_tokens was
# not metered at all. The declared per-call ceilings (plan 400K, execute 500K,
# review 400K, fix 400K, lead-review 200K) were never enforced.
#
# HOW. R, M and A1 cut the real functions (_ctx_declared_row, context_meter,
# ctx_kill_alert) out of bin/agent-call.sh with sed and run them in a subshell.
# A fake transcript reader prints one fixture line per poll (the fake token
# counter) and counts the polls. `kill` and `sleep` are shell functions: `kill
# -0` says the child is alive for <polls> polls, and `kill -TERM` records the
# TERM (and whether checkpoint-brief.md exists at that moment) instead of
# sending it. No real child, no wall clock, no network.
# A2 drives the REAL bin/agent-call.sh with a fake `claude` on PATH and the real
# bin/transcript-cost.sh (the tests/execute-no-progress.bh-8868-test.sh pattern).
# P runs the real bin/transcript-cost.sh on a fixture transcript.
#
# The lane numbers are the REAL ceiling_tokens of the manifest composed by
# bin/context-budgets-build.sh --compose into the scratch dir.
#
# CTX_DECLARED_SRC=<file> runs the R/M/A1 cases against another copy of
# agent-call.sh (the mutation check).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/context-kill-declared.bh-9124-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${CTX_DECLARED_SRC:-$DIR/bin/agent-call.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_DECLARED CONTEXT_KILL_DECLARED_UNIT CONTEXT_KILL_DECLARED_LANES
BLD="$T/builds/someproj-BH-1-202611060000"
mkdir -p "$T/logs" "$T/bin/lib" "$T/work" "$BLD"

# --- the manifest: the real one, composed; plus one lane armed by its field -----
"$DIR/bin/context-budgets-build.sh" --compose --to "$T/real.json" >/dev/null 2>&1 \
  || { echo "FAIL: cannot compose the real manifest"; exit 1; }
# fixture: the real lanes with no declared_kill field (the arming comes from
# CONTEXT_KILL_DECLARED_LANES alone), plus lane fx-armed (stage fx-armed,
# 30000) that carries declared_kill: true.
jq '.lanes |= (map(del(.declared_kill)) + [{"lane":"fx-armed","stage":"fx-armed","ceiling_tokens":30000,"declared_kill":true}])' \
  "$T/real.json" > "$T/budgets.json" || { echo "FAIL: cannot build the fixture manifest"; exit 1; }
export CONTEXT_BUDGETS="$T/budgets.json"

# --- the fake transcript reader (the fake token counter) --------------------------
cat > "$T/bin/fake-tc" <<'EOF'
#!/bin/bash
# fixture: prints FAKE_LINE, counts one poll per call, exits FAKE_RC.
n=$(cat "$POLLF" 2>/dev/null || echo 0); echo $((n + 1)) > "$POLLF"
[ "${FAKE_RC:-0}" = 0 ] || { echo "fixture: no transcript" >&2; exit "$FAKE_RC"; }
printf '%s\n' "$FAKE_LINE"
EOF
chmod +x "$T/bin/fake-tc"
# The REAL C1 brief writer, where the meter looks for it ($HARNESS/bin/lib).
scratch_install_closure bin/lib/execute-checkpoint-brief.sh "$T" >/dev/null \
  && [ -r "$T/bin/lib/execute-checkpoint-brief.sh" ] || { echo "FAIL: cannot install bin/lib/execute-checkpoint-brief.sh"; exit 1; }
# A git worktree for the meter's cwd, and a plan in the build dir, so ecb_write has real input.
git -C "$T/work" init -q 2>/dev/null
printf 'base\n' > "$T/work/README.md"
git -C "$T/work" add README.md && git -C "$T/work" -c user.email=t@t -c user.name=t commit -qm base
printf '# Plan\n\n## Acceptance tests\n\n- M1. tests/fixture-test.sh fires at ceiling+1.\n' > "$BLD/plan.md"
git -C "$T/work" rev-parse HEAD > "$BLD/collision-base"

FNS=$(sed -n '/^_ctx_declared_row()/,/^}/p; /^context_meter()/,/^}/p; /^ctx_kill_alert()/,/^}/p' "$SRC")
[ -n "$FNS" ] || { echo "FAIL: cannot extract the meter functions from $SRC"; exit 1; }

# meter <stage> <in> <cr> <peak|none> [polls] — one context_meter run. The env
# CONTEXT_KILL* / FAKE_RC / METER_CAP pass through from the caller.
meter() {
  local st="$1" in="$2" cr="$3" pk="$4" polls="${5:-1}"
  rm -f "$T/polls" "$T/terms" "$T/logs/claude-cost.log" "$BLD"/*.ctxkill "$BLD/checkpoint-brief.md"
  (
    eval "$FNS"
    HARNESS="$T"; PROJECT=someproj; STAGE="$st"; runner=claude
    OUT="$BLD/$st.out"
    _CTX_TCB="$T/bin/fake-tc"; POLLF="$T/polls"; export POLLF
    # fixture: input|output|cache_read|cache_write|usd|model|messages|files|unpriced|peak
    FAKE_LINE="$in|10|$cr|0|0.100000|claude-fixture|3|1||$pk"
    [ "$pk" = none ] && FAKE_LINE="$in|10|$cr|0|0.100000|claude-fixture|3|1|"
    export FAKE_LINE
    STAMP() { printf '2026-11-06T00:00:00Z'; }
    sleep() { :; }
    kill() {
      case "$1" in
        -0) [ "$(cat "$POLLF" 2>/dev/null || echo 0)" -lt "$polls" ] ;;
        -TERM) if [ -s "$BLD/checkpoint-brief.md" ]; then echo "TERM brief=yes"; else echo "TERM brief=no"; fi >> "$T/terms" ;;
      esac
    }
    # The cumulative cap is far above every fixture total unless METER_CAP says
    # otherwise: only the declared rule can fire.
    context_meter 4242 sid-fixture "${METER_CAP-900000000}" "$T/work"
  )
}
terms() { if [ -f "$T/terms" ]; then wc -l < "$T/terms" | tr -d ' '; else echo 0; fi; }
ckf() { cat "$BLD/$1.out.ctxkill" 2>/dev/null; }
row() { ( eval "$FNS"; _ctx_declared_row "$@" ); }

# =============================================================================
# R. _ctx_declared_row
# =============================================================================
for spec in plan:400000 execute:500000 review:400000 fix:400000 lead-review:200000; do
  st="${spec%%:*}"; want="${spec#*:}"
  got=$(row "$st" someproj claude) || got=""
  [ "$got" = "$want" ] && ok || bad "R1 $st: declared ceiling is '$got', want $want"
done
got=$(row canary someproj claude); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "R2 canary is armed with the lanes knob unset (rc=$rc ceiling '$got')"
got=$(CONTEXT_KILL_DECLARED_LANES=all row canary someproj claude); rc=$?
[ "$rc" = 0 ] && [ "$got" = 60000 ] && ok || bad "R3 CONTEXT_KILL_DECLARED_LANES=all did not arm canary (rc=$rc ceiling '$got')"
got=$(row fx-armed someproj claude); rc=$?
[ "$rc" = 0 ] && [ "$got" = 30000 ] && ok || bad "R4 a lane with declared_kill: true is not armed (rc=$rc ceiling '$got')"
got=$(CONTEXT_KILL=0 row execute someproj claude); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "R5 CONTEXT_KILL=0 did not disarm execute (rc=$rc ceiling '$got')"
got=$(eval "$FNS"; lane_switch() { [ "$1 $2" = "context-kill-off file" ]; }; _ctx_declared_row execute someproj claude); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "R5 the context-kill-off switch did not disarm execute (rc=$rc ceiling '$got')"
got=$(eval "$FNS"; lane_switch() { return 1; }; _ctx_declared_row execute someproj claude); rc=$?
[ "$rc" = 0 ] && [ "$got" = 500000 ] && ok || bad "R6 a switch read as not set disarmed execute (rc=$rc ceiling '$got')"

# =============================================================================
# M1. per lane, knobs unset: no TERM at peak = ceiling, one TERM at ceiling+1
# =============================================================================
for spec in plan:400000 execute:500000 review:400000 fix:400000 lead-review:200000; do
  st="${spec%%:*}"; want="${spec#*:}"
  meter "$st" 10 1000 "$want"
  [ "$(terms)" = 0 ] && [ -z "$(ckf "$st")" ] && ok || bad "M1 $st: killed at peak = ceiling $want (terms=$(terms))"
  meter "$st" 10 1000 "$((want + 1))"
  [ "$(terms)" = 1 ] && ok || bad "M1 $st: want 1 TERM at peak = ceiling+1, got $(terms)"
  ck=$(ckf "$st")
  case " $ck " in *" rule=declared "*"ceiling=$want "*"peak=$((want + 1)) "*) ok ;; *) bad "M1 $st: .ctxkill is '$ck'" ;; esac
  # M2. the brief exists at the TERM on execute and fix, and on no other lane.
  case "$st" in
    execute|fix) grep -qx 'TERM brief=yes' "$T/terms" 2>/dev/null && ok || bad "M2 $st: checkpoint-brief.md did not exist at the TERM ($(cat "$T/terms" 2>/dev/null))" ;;
    *)           grep -qx 'TERM brief=no' "$T/terms" 2>/dev/null && ok || bad "M2 $st: a brief was written for a $st kill ($(cat "$T/terms" 2>/dev/null))" ;;
  esac
done
meter execute 10 1000 500001
grep -q '^# Execute checkpoint brief' "$BLD/checkpoint-brief.md" 2>/dev/null && grep -q 'tests/fixture-test.sh' "$BLD/checkpoint-brief.md" \
  && ok || bad "M2 the brief is not the C1 ecb_write brief: $(head -3 "$BLD/checkpoint-brief.md" 2>/dev/null)"

# M3. unit peak: a cumulative total over the ceiling with every call under it
meter execute 100 900000 400000
[ "$(terms)" = 0 ] && ok || bad "M3 unit=peak killed on a cumulative total over the ceiling with the peak under it"

# M4. the lanes knob, space and comma lists
CONTEXT_KILL_DECLARED_LANES="plan execute" meter review 10 1000 999999
[ "$(terms)" = 0 ] && ok || bad "M4 review was killed outside CONTEXT_KILL_DECLARED_LANES=\"plan execute\""
CONTEXT_KILL_DECLARED_LANES="plan,execute" meter execute 10 1000 500001
[ "$(terms)" = 1 ] && ok || bad "M4 execute was not killed inside CONTEXT_KILL_DECLARED_LANES=\"plan,execute\""

# M5. observe, any other value, 0, CONTEXT_KILL=0
for v in observe maybe; do
  CONTEXT_KILL_DECLARED=$v meter execute 10 1000 600000 3
  [ "$(terms)" = 0 ] && [ -z "$(ckf execute)" ] && ok || bad "M5 CONTEXT_KILL_DECLARED=$v sent $(terms) TERM"
  n=$(grep -c 'CONTEXT KILL DECLARED (observe)' "$T/logs/claude-cost.log" 2>/dev/null); n=${n:-0}
  [ "$n" = 1 ] && ok || bad "M5 CONTEXT_KILL_DECLARED=$v wrote $n observe lines over 3 polls, want 1"
done
CONTEXT_KILL_DECLARED=0 meter execute 10 1000 999999
[ "$(terms)" = 0 ] && ok || bad "M5 CONTEXT_KILL_DECLARED=0 still killed"
CONTEXT_KILL=0 meter execute 10 1000 999999
[ "$(terms)" = 0 ] && ok || bad "M5 CONTEXT_KILL=0 did not turn off the declared kill"
meter plan 10 1000 400001 2
n=$(grep -c 'CONTEXT KILL DECLARED (observe)' "$T/logs/claude-cost.log" 2>/dev/null); n=${n:-0}
[ "$(terms)" = 1 ] && [ "$n" = 0 ] && ok || bad "M5 the unset knob is not armed (terms=$(terms), observe lines=$n)"

# M6. a lane outside the five, knobs unset
meter canary 10 1000 60001
[ "$(terms)" = 0 ] && [ -z "$(ckf canary)" ] && ok || bad "M6 canary at 60001 was killed with the knobs unset (terms=$(terms))"

# M7. fail-open: unreadable transcript, a 9-field line with no peak
FAKE_RC=3 meter execute 10 1000 999999 2
[ "$(terms)" = 0 ] && ok || bad "M7 an unreadable transcript killed (not fail-open)"
meter execute 10 1000 none
[ "$(terms)" = 0 ] && ok || bad "M7 a line with no peak field killed"

# M8. unit cumulative compares the session total
CONTEXT_KILL_DECLARED_UNIT=cumulative meter review 100 400000 1000
[ "$(terms)" = 1 ] && ok || bad "M8 unit=cumulative: no TERM at total 400100 > 400000"
case " $(ckf review) " in *" rule=declared "*"ceiling=400000 "*"unit=cumulative "*) ok ;; *) bad "M8 .ctxkill is '$(ckf review)'" ;; esac
CONTEXT_KILL_DECLARED_UNIT=cumulative meter review 0 400000 1000
[ "$(terms)" = 0 ] && ok || bad "M8 unit=cumulative killed at total = ceiling"

# M9. the cumulative kill wins on a poll where both fire; the meter runs with no cumulative cap
METER_CAP=1000 meter execute 10 5000 500001
[ "$(terms)" = 1 ] && ok || bad "M9 want 1 TERM, got $(terms)"
case " $(ckf execute) " in *" rule=declared "*) bad "M9 the declared rule won over the cumulative cap: $(ckf execute)" ;; *" ceiling=1000 "*) ok ;; *) bad "M9 .ctxkill is '$(ckf execute)'" ;; esac
METER_CAP="" meter execute 10 900000000 500001
[ "$(terms)" = 1 ] && case " $(ckf execute) " in *" rule=declared "*) true ;; *) false ;; esac \
  && ok || bad "M9 with no cumulative cap the declared kill did not fire (terms=$(terms), $(ckf execute))"

# =============================================================================
# A1. ctx_kill_alert names rule=declared
# =============================================================================
rm -f "$T/ALERTS.log"
(
  eval "$FNS"
  HARNESS="$T"; PROJECT=someproj; STAGE=execute; ALERTS="$T/ALERTS.log"; OUT="$T/work/none.out"
  STAMP() { printf '2026-11-06T00:00:00Z'; }
  ctx_kill_alert claude-fixture "rule=declared ceiling=500000 peak=500001 total=1010 calls=3 session=sid-fixture unit=peak"
)
grep -q 'CONTEXT KILL: execute/someproj on claude-fixture killed by rule=declared at a 500001-token API call against the declared ceiling 500000' "$T/ALERTS.log" 2>/dev/null \
  && ok || bad "A1 ctx_kill_alert does not name rule=declared: $(cat "$T/ALERTS.log" 2>/dev/null)"

# =============================================================================
# A2. DRIVEN: the real bin/agent-call.sh, a fake claude, the real transcript-cost.sh
# =============================================================================
H2="$T/h2"
mkdir -p "$H2/logs" "$H2/locks" "$H2/flags" "$H2/state" "$H2/bin" "$H2/fakebin" "$H2/.claude/projects/-work" "$H2/builds/testproj-BH-2-202611060000"
# fixture: the execute lane with its real declared ceiling and NO context_kill_tokens,
# so only the declared kill can stop it.
cat > "$H2/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"fx-exec","stage":"execute","project":"testproj","ceiling_tokens":500000,
     "target_tokens":1000,"composition":[]}
  ]
}
EOF
# One response of STUB_TOKS context tokens, then STUB_WAIT polls of quiet time, then the result.
cat > "$H2/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$T_DIR/child.pid"
PROJ="$HOME/.claude/projects/-work"
mkdir -p "$PROJ"
printf '{"type":"assistant","uuid":"u-1","timestamp":"2026-11-06T00:00:00Z","message":{"id":"msg_1","model":"claude-fable-5-1","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$((STUB_TOKS - 1))" >> "$PROJ/$sid.jsonl"
n=0
while [ "$n" -lt "${STUB_WAIT:-30}" ]; do n=$((n+1)); sleep 0.2; done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
chmod +x "$H2/fakebin/claude"
cat > "$H2/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$H2/fakebin/timeout"
for v in curl wget grok; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$v" "$H2" > "$H2/fakebin/$v"
  chmod +x "$H2/fakebin/$v"
done
: > "$H2/net.log"
printf '#!/bin/bash\necho subscription\n' > "$H2/bin/billing-mode.sh"; chmod +x "$H2/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$H2/bin/beat.sh"; chmod +x "$H2/bin/beat.sh"
WT2="$H2/wt"; mkdir -p "$WT2"; git -C "$WT2" init -q 2>/dev/null
printf 'base\n' > "$WT2/README.md"
git -C "$WT2" add README.md && git -C "$WT2" -c user.email=t@t -c user.name=t commit -qm base
B2="$H2/builds/testproj-BH-2-202611060000"
printf '# Plan\n\n## Acceptance tests\n\n- A2. tests/fixture-test.sh\n' > "$B2/plan.md"
# run_call <outfile> [env assignments...] ; echoes the rc
run_call() {
  local out="$1"; shift
  rm -f "$out" "$out".* "$B2/checkpoint-brief.md"; : > "$H2/logs/cost.csv"
  ( cd "$WT2" || exit 99
    export PATH="$H2/fakebin:$PATH" HARNESS="$H2" HOME="$H2" T_DIR="$H2" \
           CONTEXT_BUDGETS="$H2/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 CALL_GUARD=0 AGENT_LEDGER=0 LADDER_TIER2_GROK=0
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET NP_NOW
    env "$@" bash "$DIR/bin/agent-call.sh" execute testproj claude-fable-5-1 60 "$out" "execute $out" \
      >/dev/null 2>&1 )
  echo $?
}
col() { cut -d, -f"$2" <<<"$1"; }
# Warm the real reader once. On a checkout with no catalog/lanes.json (a
# git-ignored render), the first bin/transcript-cost.sh call composes it, which
# takes seconds; the meter's first poll would then end after the fake session.
HARNESS="$H2" HOME="$H2" "$DIR/bin/transcript-cost.sh" no-such-session --cwd "$WT2" >/dev/null 2>&1
# The over-ceiling session would run 30 s; the kill ends it at the first poll.
RCA=$(run_call "$B2/execute-run.txt" STUB_TOKS=500001 STUB_WAIT=150)
[ "$RCA" = 143 ] && ok || bad "A2 a 500001-token call on execute must end rc 143, got $RCA (claude-cost.log: $(tail -3 "$H2/logs/claude-cost.log" 2>/dev/null | tr '\n' ' ') ALERTS: $(tail -3 "$H2/logs/ALERTS.log" 2>/dev/null | tr '\n' ' '))"
grep -q 'rule=declared' "$B2/execute-run.txt.ctxkill" 2>/dev/null && ok || bad "A2 no .ctxkill with rule=declared: $(cat "$B2/execute-run.txt.ctxkill" 2>/dev/null)"
tail -1 "$B2/execute-run.txt" 2>/dev/null | grep -q '^CONTEXT KILL:' && ok || bad "A2 \$OUT does not end with the CONTEXT KILL: marker: $(tail -1 "$B2/execute-run.txt" 2>/dev/null)"
[ -s "$B2/checkpoint-brief.md" ] && ok || bad "A2 no checkpoint-brief.md after the execute kill"
ROW=$(grep ',execute,claude,' "$H2/logs/cost.csv" 2>/dev/null | tail -1)
case "$(col "$ROW" 24)" in *context-kill:ceiling=500000*) ok ;; *) bad "A2 cost row note is '$(col "$ROW" 24)', want context-kill:ceiling=500000" ;; esac
RCB=$(run_call "$B2/execute-run.txt" STUB_TOKS=500000 STUB_WAIT=15)
[ "$RCB" = 0 ] && [ ! -f "$B2/execute-run.txt.ctxkill" ] && ok || bad "A2 a 500000-token call was killed (rc $RCB, $(cat "$B2/execute-run.txt.ctxkill" 2>/dev/null))"
[ "$(cat "$B2/execute-run.txt" 2>/dev/null)" = "CLEAN DONE" ] && ok || bad "A2 the call at the ceiling did not finish: $(cat "$B2/execute-run.txt" 2>/dev/null)"
[ ! -s "$H2/net.log" ] && ok || bad "A2 a network/vendor stub was called: $(cat "$H2/net.log")"

# =============================================================================
# P. bin/transcript-cost.sh --peak on a fixture transcript
# =============================================================================
# fixture: 3 API responses; msg_b is written twice (two content blocks, one
# usage), so the peak is read per response, never summed across its lines.
mkdir -p "$T/tc"
cat > "$T/tc/fixture-session.jsonl" <<'EOF'
{"type":"user","uuid":"u-0","timestamp":"2026-11-06T00:00:00Z","message":{"role":"user","content":"fixture"}}
{"type":"assistant","uuid":"u-1","timestamp":"2026-11-06T00:00:01Z","message":{"id":"msg_a","model":"claude-fixture","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}
{"type":"assistant","uuid":"u-2","timestamp":"2026-11-06T00:00:02Z","message":{"id":"msg_b","model":"claude-fixture","usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":200000,"cache_creation_input_tokens":300}}}
{"type":"assistant","uuid":"u-3","timestamp":"2026-11-06T00:00:02Z","message":{"id":"msg_b","model":"claude-fixture","usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":200000,"cache_creation_input_tokens":300}}}
{"type":"assistant","uuid":"u-4","timestamp":"2026-11-06T00:00:03Z","message":{"id":"msg_c","model":"claude-fixture","usage":{"input_tokens":2,"output_tokens":5,"cache_read_input_tokens":150000,"cache_creation_input_tokens":60000}}}
EOF
printf '{"per_token": {}}\n' > "$T/tc/prices.json"
TCB="$DIR/bin/transcript-cost.sh"
tcr() { HARNESS="$T" LANE_GATE_DISABLE=1 "$TCB" "$T/tc/fixture-session.jsonl" --prices "$T/tc/prices.json" "$@" 2>/dev/null; }
L=$(tcr --peak)
[ "$(cut -d'|' -f10 <<<"$L")" = 210002 ] && ok || bad "P1 --peak field 10 is '$(cut -d'|' -f10 <<<"$L")', want 210002 (line: $L)"
[ "$(cut -d'|' -f7 <<<"$L")" = 3 ] && ok || bad "P1 the fixture counts $(cut -d'|' -f7 <<<"$L") responses, want 3"
L9=$(tcr)
[ "$(awk -F'|' '{print NF}' <<<"$L9")" = 9 ] && ok || bad "P2 without --peak the line has $(awk -F'|' '{print NF}' <<<"$L9") fields, want 9"
[ "$L9|210002" = "$L" ] && ok || bad "P2 --peak changed a field other than the last ($L9 vs $L)"
L11=$(tcr --price-version --peak)
[ "$(awk -F'|' '{print NF}' <<<"$L11")" = 11 ] && [ "$(cut -d'|' -f11 <<<"$L11")" = 210002 ] \
  && ok || bad "P3 with --price-version, peak is not field 11: $L11"
HLP=$("$TCB" --help 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q -- '--peak' <<<"$HLP" && grep -q -- '--price-version' <<<"$HLP" \
  && ok || bad "P4 --help (rc $rc) does not print the --peak header"

# =============================================================================
# K1. each knob default equals the code fallback
# =============================================================================
KF="$DIR/catalog/lanes.d/_lib.context-kill-declared.json"
kd() { jq -r --arg e "$1" '.libs[] | select(.id == "context-kill-declared") | .knobs[] | select(.env == $e) | .default' "$KF" 2>/dev/null; }
[ "$(kd CONTEXT_KILL_DECLARED)" = 1 ] && grep -q 'CONTEXT_KILL_DECLARED:-1}' "$SRC" \
  && ok || bad "K1 CONTEXT_KILL_DECLARED default is '$(kd CONTEXT_KILL_DECLARED)' or the code fallback is not 1"
[ "$(kd CONTEXT_KILL_DECLARED_UNIT)" = peak ] && grep -q 'CONTEXT_KILL_DECLARED_UNIT:-peak}' "$SRC" \
  && ok || bad "K1 CONTEXT_KILL_DECLARED_UNIT default is '$(kd CONTEXT_KILL_DECLARED_UNIT)' or the code fallback is not peak"
[ "$(kd CONTEXT_KILL_DECLARED_LANES)" = "plan execute review fix lead-review" ] \
  && grep -q 'CONTEXT_KILL_DECLARED_LANES:-plan execute review fix lead-review}' "$SRC" \
  && ok || bad "K1 CONTEXT_KILL_DECLARED_LANES default is '$(kd CONTEXT_KILL_DECLARED_LANES)' or the code fallback differs"

echo "context-kill-declared.bh-9124: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
