#!/bin/bash
# tests/budget-stop-tracer-test.sh — HARD CAPS per (build, stage), the tracer
# (BH-4488, wave 1 of BH-4475): the execute stage, end to end. BH-4489 widened
# the build-stage scope to every stage; U1, U4 and A5 changed with it.
#
#   U1..U6  bin/lib/budget-stop.sh driven directly (cap read, total, verdict,
#           the one-caller trip)
#   A1..A6  the REAL bin/agent-call.sh against a fake `claude` that appends to
#           an order sink: under the cap the call runs; at the cap nothing is
#           called, the build gets its BUDGET_STOP marker and ONE alert line;
#           a retried tick stays stopped; out-of-scope calls are never refused;
#           an unreadable cap fails closed with its own reason
#   C1..C3  the REAL CC() lifted from the flattened pipeline: the terminal
#           budget_stop phase and RESULT "BUILD_REFUSED BUDGET_STOP ..."
#   N1      the console's stage mapping (node --test), when node is here
#
# Run from anywhere: tests/budget-stop-tracer-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/budget-stop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# row <stage> <cost_usd> — one cost.csv row in the writer's column order
row() { printf '2026-10-04T00:00:00Z,box,testproj,%s,claude,claude-fable-5-1,0,1,10,2,0,0,%s,subscription,fp,acct,sid,envelope,,,,,,,fly-pool,\n' "$1" "$2"; }
# settings <json-values> — a fresh settings cache under $T/state
settings() { mkdir -p "$T/state"; jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }

# =============================================================================
# U1 — sources under set -eu; every function defined; no token cap is read
# =============================================================================
U1=$(HARNESS="$T" bash -c 'set -euo pipefail; . "$1"
  for f in bs_applies bs_cap bs_total bs_check bs_trip; do declare -F "$f" >/dev/null || echo "undefined:$f"; done
  echo sourced' _ "$LIB" 2>&1)
[ "$(tail -1 <<<"$U1")" = sourced ] && ok || bad "U1 sourcing under set -eu: $U1"
grep -q '^undefined:' <<<"$U1" && bad "U1 missing: $U1" || ok
# BH-4489: max_tokens is an axis now (it was out of scope for the tracer).
grep -q 'max_tokens' <<<"$(grep -v '^[[:space:]]*#' "$LIB")" && ok || bad "U1 the lib reads no max_tokens key (BH-4489 axis)"

# =============================================================================
# U2 — bs_cap: absent / number / padded / off / junk / corrupt cache / no cache
# =============================================================================
cap() { HARNESS="$T" bash -c '. "$1"; bs_cap execute "$2" > "$3"; rc=$?; echo "$rc:$(cat "$3"):$BS_REASON"' _ "$LIB" "$1" "$T/cap.out" 2>/dev/null; }
rm -rf "$T/state"
[ "$(cap max_calls)" = "1::" ] && ok || bad "U2 no cache: '$(cap max_calls)', want 1::"
settings '{}'
[ "$(cap max_calls)" = "1::" ] && ok || bad "U2 absent key: '$(cap max_calls)'"
settings '{"budget.stage.execute.max_calls":"3"}'
[ "$(cap max_calls)" = "0:3:" ] && ok || bad "U2 \"3\": '$(cap max_calls)'"
settings '{"budget.stage.execute.max_calls":" 3 "}'
[ "$(cap max_calls)" = "0:3:" ] && ok || bad "U2 \" 3 \": '$(cap max_calls)'"
settings '{"budget.stage.execute.max_usd":2.5}'
[ "$(cap max_usd)" = "0:2.5:" ] && ok || bad "U2 max_usd 2.5 (a JSON number): '$(cap max_usd)'"
settings '{"budget.stage.execute.max_calls":"off"}'
[ "$(cap max_calls)" = "1::" ] && ok || bad "U2 off: '$(cap max_calls)'"
settings '{"budget.stage.execute.max_calls":"lots"}'
[ "$(cap max_calls)" = "2::cap-unreadable:budget.stage.execute.max_calls" ] && ok || bad "U2 lots: '$(cap max_calls)'"
settings '{"budget.stage.execute.max_calls":"2.5"}'
[ "$(cap max_calls)" = "2::cap-unreadable:budget.stage.execute.max_calls" ] && ok || bad "U2 max_calls 2.5: '$(cap max_calls)'"
printf '{not json' > "$T/state/settings-cache.json"
[ "$(cap max_calls)" = "2::settings-unreadable" ] && ok || bad "U2 corrupt cache: '$(cap max_calls)'"

# =============================================================================
# U3 — bs_total: exact stage, advisor and review rows excluded, unpriced counted
# =============================================================================
mkdir -p "$T/u3"
{ echo "$HDR"; row execute 1.25; row execute-advisor 9.00; row review 4.00; row execute ""; row execute 0.75; } > "$T/u3/cost.csv"
U3=$(bash -c '. "$1"; bs_total "$2" execute' _ "$LIB" "$T/u3/cost.csv")
[ "$U3" = "3 2.00 1" ] && ok || bad "U3 total '$U3', want '3 2.00 1'"
U3H=$(bash -c '. "$1"; bs_total "$2" execute' _ "$LIB" <(echo "$HDR"))
[ "$U3H" = "0 0.00 0" ] && ok || bad "U3 header-only '$U3H'"
U3M=$(bash -c '. "$1"; bs_total "$2" execute; echo "rc=$?"' _ "$LIB" "$T/u3/nope.csv" | tr '\n' ' ')
[ "$U3M" = "0 0.00 0 rc=0 " ] && ok || bad "U3 missing csv '$U3M'"
if [ "$(id -u)" != 0 ]; then
  cp "$T/u3/cost.csv" "$T/u3/locked.csv"; chmod 000 "$T/u3/locked.csv"
  U3U=$(bash -c '. "$1"; bs_total "$2" execute; echo "rc=$?"' _ "$LIB" "$T/u3/locked.csv")
  [ "$U3U" = "rc=2" ] && ok || bad "U3 unreadable csv '$U3U', want rc=2"
fi

# =============================================================================
# U4 — bs_applies: a build dir, any stage (execute only until BH-4489)
# =============================================================================
U4=$(bash -c '. "$1"
  for c in "execute /x/builds/b1/execute-run.txt" "execute /x/other/out.txt" "fix /x/builds/b1/fix.txt" \
           "execute-advisor /x/builds/b1/a.txt" "plan /x/builds/b1/plan-run.txt"; do
    set -- $c; bs_applies "$1" "$2" && echo "y" || echo "n"; done' _ "$LIB" | tr -d '\n')
# BH-4489: every stage is capped now; only "not a build dir" stays out.
[ "$U4" = "ynyyy" ] && ok || bad "U4 bs_applies '$U4', want ynyyy"

# =============================================================================
# U5 — the verdict line, exactly; U6 — two concurrent trips, one marker, one alert
# =============================================================================
mkdir -p "$T/bin" "$T/logs" "$T/u5"
cp "$DIR/bin/alert-line.sh" "$T/bin/alert-line.sh"; chmod +x "$T/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
: > "$T/logs/ALERTS.log"
settings '{"budget.stage.execute.max_calls":"2"}'
{ echo "$HDR"; row execute 1.00; row execute ""; } > "$T/u5/cost.csv"
U5=$(HARNESS="$T" bash -c '. "$1"; bs_check testproj execute "$2"; echo "rc=$?"; echo "$BS_LINE"' _ "$LIB" "$T/u5")
[ "$U5" = "rc=1
budget_stop execute max_calls calls=2 max_calls=2 usd=1.00 max_usd=- unpriced=1" ] && ok || bad "U5 verdict: '$U5'"
[ "$(head -1 "$T/u5/BUDGET_STOP" 2>/dev/null)" = "budget_stop execute max_calls calls=2 max_calls=2 usd=1.00 max_usd=- unpriced=1" ] \
  && ok || bad "U5 marker line 1: $(head -1 "$T/u5/BUDGET_STOP" 2>/dev/null)"
grep -q 'budget.stage.execute.max_calls' "$T/u5/BUDGET_STOP" 2>/dev/null && ok || bad "U5 marker does not name the cap key"
mkdir -p "$T/u6"; : > "$T/logs/ALERTS.log"
for i in 1 2 3 4; do
  HARNESS="$T" bash -c '. "$1"; bs_trip testproj "$2" "budget_stop execute max_calls caller-$3"' _ "$LIB" "$T/u6" "$i" &
done; wait
[ "$(grep -c 'budget-stop' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "U6 alerts after 4 concurrent trips: $(grep -c 'budget-stop' "$T/logs/ALERTS.log"), want 1"
[ "$(grep -c '^budget_stop' "$T/u6/BUDGET_STOP" 2>/dev/null)" = 1 ] && ok || bad "U6 marker: $(cat "$T/u6/BUDGET_STOP" 2>/dev/null)"
grep -q '\[budget-stop\] BUDGET_STOP testproj build u6' "$T/logs/ALERTS.log" && ok || bad "U6 alert text: $(cat "$T/logs/ALERTS.log")"

# =============================================================================
# the agent-call fixture (as tests/tripwire-seams.bh-3481-test.sh)
# =============================================================================
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/builds"
echo '{"lanes":[]}' > "$T/budgets.json"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  rm -f "$T/logs/cost.csv"; rm -rf "$T/builds" "$T/other"; mkdir -p "$T/builds" "$T/other"
}
# seed <build> <stage:cost>... — a build dir whose cost.csv holds those rows
seed() { local b="$T/builds/$1"; shift; mkdir -p "$b"; { echo "$HDR"; for r in "$@"; do row "${r%%:*}" "${r#*:}"; done; } > "$b/cost.csv"; }
# call <stage> <out> [VAR=VAL ...] -> prints the rc; stderr to $T/err
call() {
  local st="$1" out="$2"; shift 2
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID
    export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$st" testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
nexec() { grep -c ",execute,claude," "$1" 2>/dev/null; }

# A1 — under the cap: the call runs and the total rises
reset; settings '{"budget.stage.execute.max_calls":"2"}'; seed a1 execute:0.10
R=$(call execute "$T/builds/a1/execute-run.txt")
[ "$R" = 0 ] && ok || bad "A1 rc=$R, want 0: $(head -3 "$T/err")"
[ "$(cat "$T/order")" = claude ] && ok || bad "A1 claude not invoked: '$(cat "$T/order")'"
[ "$(nexec "$T/builds/a1/cost.csv")" = 2 ] && ok || bad "A1 build execute rows $(nexec "$T/builds/a1/cost.csv"), want 2"
[ -e "$T/builds/a1/BUDGET_STOP" ] && bad "A1 a marker was written under the cap" || ok

# A2 — at the cap: refused before the call, marker, one alert, ledger unchanged
reset; settings '{"budget.stage.execute.max_calls":"2"}'; seed a2 execute:0.10 execute:0.20
cp "$T/builds/a2/cost.csv" "$T/a2-before.csv"
R=$(call execute "$T/builds/a2/execute-run.txt")
[ "$R" = 74 ] && ok || bad "A2 rc=$R, want 74: $(head -3 "$T/err")"
[ -s "$T/order" ] && bad "A2 claude was invoked over the cap: $(cat "$T/order")" || ok
grep -q '^AGENT_CALL_REFUSED budget-stop budget_stop execute max_calls ' <<<"$(head -1 "$T/builds/a2/execute-run.txt" 2>/dev/null)" \
  && ok || bad "A2 \$OUT: $(head -1 "$T/builds/a2/execute-run.txt" 2>/dev/null)"
[ "$(head -1 "$T/builds/a2/BUDGET_STOP" 2>/dev/null)" = "budget_stop execute max_calls calls=2 max_calls=2 usd=0.30 max_usd=- unpriced=0" ] \
  && ok || bad "A2 marker: $(head -1 "$T/builds/a2/BUDGET_STOP" 2>/dev/null)"
[ "$(grep -c 'budget-stop' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "A2 alert lines: $(grep -c 'budget-stop' "$T/logs/ALERTS.log"), want 1"
cmp -s "$T/a2-before.csv" "$T/builds/a2/cost.csv" && ok || bad "A2 build cost.csv changed on a refusal"
grep -q ',execute,.*budget-stop:max_calls' "$T/logs/cost.csv" 2>/dev/null && ok || bad "A2 no refused row in the global ledger"
grep -q 'BUDGET-STOP REFUSED' "$T/logs/failovers.log" && ok || bad "A2 no failovers line"

# A3 — max_usd: priced rows summing 5.00 against a 5 cap
reset; settings '{"budget.stage.execute.max_usd":"5"}'; seed a3 execute:2.50 execute:2.50 execute-advisor:1.00
R=$(call execute "$T/builds/a3/execute-run.txt")
[ "$R" = 74 ] && ok || bad "A3 rc=$R, want 74"
[ -s "$T/order" ] && bad "A3 claude invoked" || ok
grep -q '^budget_stop execute max_usd calls=2 max_calls=- usd=5.00 max_usd=5 ' <<<"$(head -1 "$T/builds/a3/BUDGET_STOP" 2>/dev/null)" \
  && ok || bad "A3 marker: $(head -1 "$T/builds/a3/BUDGET_STOP" 2>/dev/null)"

# A4 — a retried tick: twice more, the second with the cap row gone
reset; settings '{"budget.stage.execute.max_calls":"2"}'; seed a4 execute:0.10 execute:0.20
R0=$(call execute "$T/builds/a4/execute-run.txt"); cp "$T/builds/a4/BUDGET_STOP" "$T/a4-marker"
R1=$(call execute "$T/builds/a4/execute-run.txt")
settings '{}'
R2=$(call execute "$T/builds/a4/execute-run.txt")
[ "$R0/$R1/$R2" = 74/74/74 ] && ok || bad "A4 rcs $R0/$R1/$R2, want 74/74/74"
[ -s "$T/order" ] && bad "A4 claude invoked on a retried tick: $(cat "$T/order")" || ok
cmp -s "$T/a4-marker" "$T/builds/a4/BUDGET_STOP" && ok || bad "A4 marker content changed on retry"
[ "$(grep -c 'budget-stop' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "A4 alert lines: $(grep -c 'budget-stop' "$T/logs/ALERTS.log"), want 1"

# A5 — negatives: none of these may refuse
a5() { # a5 <label> <stage> <out> <settings-json|NONE> [seed rows...]
  local l="$1" st="$2" out="$3" s="$4"; shift 4
  reset
  if [ "$s" = NONE ]; then rm -f "$T/state/settings-cache.json"; else settings "$s"; fi
  mkdir -p "$(dirname "$out")"
  [ "$#" -gt 0 ] && seed "$(basename "$(dirname "$out")")" "$@"
  local r; r=$(call "$st" "$out")
  [ "$r" = 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "A5 $l: rc=$r order='$(cat "$T/order")' $(head -2 "$T/err")"
  [ -e "$(dirname "$out")/BUDGET_STOP" ] && bad "A5 $l wrote a marker" || true
}
ZERO='{"budget.stage.execute.max_calls":"0","budget.stage.execute.max_usd":"0","budget.stage.fix.max_calls":"0","budget.stage.review.max_calls":"0","budget.stage.plan.max_calls":"0"}'
# BH-4489: every stage is capped now. A zero cap written for fix/review/plan
# refuses them exactly as it refuses execute (these three ran under the tracer).
for st in fix review plan; do
  reset; settings "$ZERO"; mkdir -p "$T/builds/n-$st"
  R=$(call "$st" "$T/builds/n-$st/$st-run.txt")
  [ "$R" = 74 ] && [ ! -s "$T/order" ] && ok || bad "A5 $st with a zero cap: rc=$R order='$(cat "$T/order")', want 74 and nothing called"
  grep -q "^budget_stop $st max_calls calls=0 max_calls=0 " <<<"$(head -1 "$T/builds/n-$st/BUDGET_STOP" 2>/dev/null)" \
    && ok || bad "A5 $st marker: $(head -1 "$T/builds/n-$st/BUDGET_STOP" 2>/dev/null)"
done
a5 not-a-build execute "$T/other/execute-run.txt"    "$ZERO"
a5 no-cache    execute "$T/builds/n5/execute-run.txt" NONE execute:1.00 execute:1.00
a5 off         execute "$T/builds/n6/execute-run.txt" '{"budget.stage.execute.max_calls":"off"}' execute:1.00
a5 below-cap   execute "$T/builds/n7/execute-run.txt" '{"budget.stage.execute.max_calls":"3"}' execute:1.00 execute:1.00
a5 advisor     execute "$T/builds/n8/execute-run.txt" '{"budget.stage.execute.max_calls":"1"}' execute-advisor:1.00 execute-advisor:1.00
a5 unpriced    execute "$T/builds/n9/execute-run.txt" '{"budget.stage.execute.max_calls":"5","budget.stage.execute.max_usd":"1"}' execute: execute:

# A6 — fail closed, each with its own reason
reset; settings '{"budget.stage.execute.max_calls":"lots"}'; seed a6 execute:0.10
R=$(call execute "$T/builds/a6/execute-run.txt")
[ "$R" = 74 ] && ok || bad "A6a rc=$R, want 74"
[ -s "$T/order" ] && bad "A6a claude invoked on an unreadable cap" || ok
grep -q '^budget_stop execute cap-unreadable:budget.stage.execute.max_calls ' <<<"$(head -1 "$T/builds/a6/BUDGET_STOP" 2>/dev/null)" \
  && ok || bad "A6a marker: $(head -1 "$T/builds/a6/BUDGET_STOP" 2>/dev/null)"
reset; mkdir -p "$T/state"; printf '{"fetched_at":%s,"values":' "$(date -u +%s)" > "$T/state/settings-cache.json"; seed a6 execute:0.10
R=$(call execute "$T/builds/a6/execute-run.txt")
[ "$R" = 74 ] && ok || bad "A6b rc=$R, want 74"
[ -s "$T/order" ] && bad "A6b claude invoked on a corrupt cache" || ok
grep -q '^budget_stop execute settings-unreadable ' <<<"$(head -1 "$T/builds/a6/BUDGET_STOP" 2>/dev/null)" \
  && ok || bad "A6b marker: $(head -1 "$T/builds/a6/BUDGET_STOP" 2>/dev/null)"

# A7 — a box whose sync has not landed the lib: the marker is still honoured
# inline (a copy of the real bin/ with budget-stop.sh removed)
rm -rf "$T/nolib"; mkdir -p "$T/nolib"; cp -R "$DIR/bin" "$T/nolib/bin"; rm -f "$T/nolib/bin/lib/budget-stop.sh"
reset; settings '{}'; seed a7 execute:0.10
printf 'budget_stop execute max_calls calls=1 max_calls=1 usd=0.10 max_usd=- unpriced=0\n' > "$T/builds/a7/BUDGET_STOP"
R=$(DIR="$T/nolib" call review "$T/builds/a7/review-run.txt")
[ "$R" = 74 ] && ok || bad "A7 rc=$R, want 74 (marker honoured without the lib): $(head -2 "$T/err")"
[ -s "$T/order" ] && bad "A7 claude invoked on a stopped build without the lib" || ok
grep -qx 'AGENT_CALL_REFUSED budget-stop budget_stop execute max_calls calls=1 max_calls=1 usd=0.10 max_usd=- unpriced=0' <<<"$(head -1 "$T/builds/a7/review-run.txt" 2>/dev/null)" \
  && ok || bad "A7 \$OUT: $(head -1 "$T/builds/a7/review-run.txt" 2>/dev/null)"
# and without the lib and without a marker the call runs as before
reset; settings '{"budget.stage.execute.max_calls":"0"}'; seed a7 execute:0.10
R=$(DIR="$T/nolib" call execute "$T/builds/a7/execute-run.txt")
[ "$R" = 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "A7 no-lib no-marker call refused: rc=$R $(head -2 "$T/err")"

# =============================================================================
# C1..C3 — the real CC() dispatcher
# =============================================================================
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "C could not extract CC() from the pipeline"
mkdir -p "$T/h/bin"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
touch "$SINK/agent-call"
[ -n "${WRITE_BS:-}" ] && printf 'budget_stop execute max_calls calls=2 max_calls=2 usd=0.30 max_usd=- unpriced=0\ncaps read: x\n' > "$BUILD/BUDGET_STOP"
exit "${AC_RC:-0}"
STUB
chmod +x "$T/h/bin/agent-call.sh"
cc() {
  local c="$1"; shift
  rm -rf "$T/cc/$c"; mkdir -p "$T/cc/$c/build"
  [ -n "${PRE_BS:-}" ] && printf '%s\ncaps read: y\n' "$PRE_BS" > "$T/cc/$c/build/BUDGET_STOP"
  ( export SINK="$T/cc/$c" BUILD="$T/cc/$c/build" "$@"
    bash -c '
      set -uo pipefail
      HARNESS="'"$T"'/h"; PROJECT=demo-os; KEY=DEMO-1; CG_ORIENT=x
      BB() { printf "%s|%s|%s\n" "$1" "${3:-}" "${6:-}" >> "$SINK/bb"; }
      RESULT() { printf "%s\n" "$*" >> "$SINK/result"; }
      . "'"$T"'/cc.sh"
      CC execute model 60 "$BUILD/execute-run.txt" "PROMPT"
      echo "returned $?" > "$SINK/returned"' )
  echo $?
}
R=$(PRE_BS="budget_stop execute max_usd calls=3 max_calls=- usd=5.10 max_usd=5 unpriced=0" cc c1)
[ "$R" = 3 ] && ok || bad "C1 rc=$R, want 3"
[ -e "$T/cc/c1/agent-call" ] && bad "C1 agent-call ran on a stopped build" || ok
[ "$(cat "$T/cc/c1/result" 2>/dev/null)" = "BUILD_REFUSED BUDGET_STOP budget_stop execute max_usd calls=3 max_calls=- usd=5.10 max_usd=5 unpriced=0" ] \
  && ok || bad "C1 RESULT: $(cat "$T/cc/c1/result" 2>/dev/null)"
grep -q '^budget_stop|BUDGET_STOP|budget_stop execute max_usd' "$T/cc/c1/bb" 2>/dev/null && ok || bad "C1 BB: $(cat "$T/cc/c1/bb" 2>/dev/null)"
[ -e "$T/cc/c1/returned" ] && bad "C1 CC returned instead of ending the build" || ok
R=$(cc c2 WRITE_BS=1 AC_RC=74)
[ "$R" = 3 ] && ok || bad "C2 rc=$R, want 3"
[ -e "$T/cc/c2/agent-call" ] && ok || bad "C2 agent-call did not run"
[ "$(cat "$T/cc/c2/result" 2>/dev/null)" = "BUILD_REFUSED BUDGET_STOP budget_stop execute max_calls calls=2 max_calls=2 usd=0.30 max_usd=- unpriced=0" ] \
  && ok || bad "C2 RESULT: $(cat "$T/cc/c2/result" 2>/dev/null)"
R=$(cc c3 AC_RC=7)
[ "$R" = 0 ] && [ "$(cat "$T/cc/c3/returned" 2>/dev/null)" = "returned 7" ] && ok || bad "C3 rc passthrough: $R $(cat "$T/cc/c3/returned" 2>/dev/null)"
[ -e "$T/cc/c3/result" ] || [ -e "$T/cc/c3/bb" ] && bad "C3 RESULT/BB written with no marker" || ok
# A leftover TRIPWIRE beside BUDGET_STOP: BUDGET_STOP ends the build, because
# the tripwire never stops a build since BH-6705
rm -rf "$T/cc/c4"; mkdir -p "$T/cc/c4/build"; echo "spend 1 2" > "$T/cc/c4/build/TRIPWIRE"; echo "budget_stop x" > "$T/cc/c4/build/BUDGET_STOP"
( export SINK="$T/cc/c4" BUILD="$T/cc/c4/build"
  bash -c 'HARNESS="'"$T"'/h"; PROJECT=demo-os; KEY=DEMO-1
    BB() { :; }; RESULT() { printf "%s\n" "$*" >> "$SINK/result"; }
    . "'"$T"'/cc.sh"; CC execute model 60 "$BUILD/execute-run.txt" P' )
[ "$(cat "$T/cc/c4/result" 2>/dev/null)" = "BUILD_REFUSED BUDGET_STOP budget_stop x" ] && ok || bad "C4 a leftover TRIPWIRE beside BUDGET_STOP: $(cat "$T/cc/c4/result" 2>/dev/null)"

# =============================================================================
# N1 — the console stage mapping (console-ui/src/lib/stages.js)
# =============================================================================
STAGES_JS="$DIR/console-ui/src/lib/stages.js"
if command -v node >/dev/null 2>&1; then
  N1=$(cd "$DIR/console-ui" && node --test tests/stages.bh-4488.test.js 2>&1); N1RC=$?
  [ "$N1RC" = 0 ] && ok || bad "N1 node --test stages.bh-4488 rc=$N1RC: $(tail -20 <<<"$N1")"
  [ -r "$STAGES_JS" ] && ok || bad "N1 $STAGES_JS missing"
else
  echo "node missing — N1 skipped"
fi

echo "budget-stop-tracer-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
