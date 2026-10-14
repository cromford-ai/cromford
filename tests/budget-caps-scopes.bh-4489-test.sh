#!/bin/bash
# tests/budget-caps-scopes.bh-4489-test.sh — HARD CAPS on every stage and
# scope (BH-4489, wave 2 of BH-4475). The ticket names this suite
# tests/budget-caps-scopes-test.sh; the per-ticket naming rule puts it here.
#
#   S1   every build stage is capped (build-stage scope, max_calls)
#   S2   the max_tokens axis
#   S3   stage-day scope, a lane call outside any build
#   S4   project-day scope
#   S5   a stage with no row of its own (research / Archie) via _default
#   S6   a build-stage overrun wins (terminal), else the tightest scope; the
#        others are named
#   S7   no cross-talk, and no spend read without a cap
#   S8   finishes nothing mid-call
#   S9   the launch gate in bin/lib/rb/gates.sh stops new builds, on the
#        project-day cap and on any build stage's stage-day cap; two attempts
#        of one ticket under a review stage-day cap, the second buys nothing
#   S10  CC() defers an in-flight build on a day cap; the pool does not count it
#   S11  fail closed inside a build, open outside it
#   S12  adversarial negatives
#   S13  key legality: illegal stage / long project names fall to _default
#
# Drives the REAL bin/agent-call.sh with the real jobs client against a fake
# curl worker, a fake `claude` appending to an order sink, and asserts on
# artifacts only.
# Run from anywhere: tests/budget-caps-scopes.bh-4489-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 118 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/budget-stop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
TODAY=$(date -u +%Y%m%d)

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# row <stage> <cost_usd> [in,out,cr,cw] — one cost.csv row in the writer's column order
row() { printf '2026-10-04T00:00:00Z,box,testproj,%s,claude,claude-fable-5-1,0,1,%s,%s,subscription,fp,acct,sid,envelope,,,,,,fly-pool,\n' "$1" "${3:-10,2,0,0}" "$2"; }
settings() { mkdir -p "$T/state"; jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
# spend <file-stem> <usd> [calls] [refused] [settled] — what llm-spend answers
spend() { mkdir -p "$T/spend"; printf '{"usd":%s,"calls":%s,"refused":%s,"settled":%s,"since":"x"}' "$2" "${3:-1}" "${4:-0}" "${5:-0}" > "$T/spend/$1.json"; }

# =============================================================================
# fixture: the real agent-call + jobs client, a fake worker, a fake claude
# =============================================================================
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/builds" "$T/bin/lib/jobs" "$T/logs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh" 2>/dev/null || true
cp "$DIR/bin/alert-line.sh" "$T/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
echo '{"lanes":[]}' > "$T/budgets.json"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
trap 'echo TERM >> "$SIG_SINK"' TERM
trap 'echo INT >> "$SIG_SINK"' INT
echo claude >> "$ORDER_SINK"
# S8: the project's day spend crosses its cap WHILE this call runs
[ -n "${MIDCALL_SPEND:-}" ] && printf '{"usd":%s,"calls":3,"refused":0,"settled":0}' "$MIDCALL_SPEND" > "$SPEND_DIR/testproj.json"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The worker: llm-spend from $SPEND_DIR/<project>[.<stage>].json (zeros when
# absent), every other path 404. SPEND_FAKE=down = transport failure.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$REQ_LOG"
case "$URL" in
  */api/metrics/llm-spend\?*)
    [ "${SPEND_FAKE:-}" = down ] && exit 7
    q="${URL#*\?}"; p=""; s=""
    IFS='&' read -r -a kv <<<"$q"
    for x in "${kv[@]}"; do case "$x" in project=*) p="${x#project=}" ;; stage=*) s="${x#stage=}" ;; esac; done
    f="$SPEND_DIR/$p${s:+.$s}.json"
    if [ -s "$f" ]; then cat "$f"; else printf '{"usd":0,"calls":0,"refused":0,"settled":0}'; fi
    printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/req.log"; : > "$T/sig"
  rm -f "$T/logs/cost.csv" "$T/flags/"*; rm -rf "$T/builds" "$T/lane" "$T/spend"
  mkdir -p "$T/builds" "$T/lane" "$T/spend"
}
seed() { local b="$T/builds/$1"; shift; mkdir -p "$b"; { echo "$HDR"; for r in "$@"; do row "${r%%:*}" "${r#*:}"; done; } > "$b/cost.csv"; }
# call <stage> <out> [VAR=VAL ...] -> prints the rc. PROJ=<p> picks the project.
call() {
  local st="$1" out="$2"; shift 2
  mkdir -p "$(dirname "$out")"
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID
    export ORDER_SINK="$T/order" SIG_SINK="$T/sig" REQ_LOG="$T/req.log" SPEND_DIR="$T/spend" \
           PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           HARNESS_SECRET=testsecret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$st" "${PROJ:-testproj}" claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
norder() { grep -c . "$T/order"; }
line1()  { head -1 "$1" 2>/dev/null; }
nalerts() { grep -c "${1:-budget}" "$T/logs/ALERTS.log"; }
nspend() { grep -c '/api/metrics/llm-spend' "$T/req.log"; }

# =============================================================================
# S1 — every build stage: max_calls=1 with one seeded row is over
# =============================================================================
for s in plan review fix qa execute; do
  reset; settings "{\"budget.stage.$s.max_calls\":\"1\"}"; seed "s1$s" "$s:0.10"
  R=$(call "$s" "$T/builds/s1$s/$s-run.txt")
  [ "$R" = 74 ] && ok || bad "S1 $s rc=$R, want 74: $(head -2 "$T/err")"
  [ "$(norder)" = 0 ] && ok || bad "S1 $s claude invoked over the cap"
  grep -q "^budget_stop $s max_calls calls=1 max_calls=1 " <<<"$(line1 "$T/builds/s1$s/BUDGET_STOP")" \
    && ok || bad "S1 $s marker: $(line1 "$T/builds/s1$s/BUDGET_STOP")"
done

# =============================================================================
# S2 — max_tokens: the four token cells, summed
# =============================================================================
reset; settings '{"budget.stage.plan.max_tokens":"1000"}'
mkdir -p "$T/builds/s2a"; { echo "$HDR"; row plan 0.10 600,300,50,50; } > "$T/builds/s2a/cost.csv"
R=$(call plan "$T/builds/s2a/plan-run.txt")
[ "$R" = 74 ] && [ "$(norder)" = 0 ] && ok || bad "S2 1000 tokens: rc=$R order=$(norder)"
grep -q '^budget_stop plan max_tokens .* tokens=1000 max_tokens=1000' <<<"$(line1 "$T/builds/s2a/BUDGET_STOP")" \
  && ok || bad "S2 marker: $(line1 "$T/builds/s2a/BUDGET_STOP")"
reset; settings '{"budget.stage.plan.max_tokens":"1000"}'
mkdir -p "$T/builds/s2b"; { echo "$HDR"; row plan 0.10 600,300,50,49; } > "$T/builds/s2b/cost.csv"
R=$(call plan "$T/builds/s2b/plan-run.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S2 999 tokens: rc=$R order=$(norder) $(head -2 "$T/err")"
reset; settings '{"budget.stage.plan.max_tokens":"1000"}'
mkdir -p "$T/builds/s2c"; { echo "$HDR"; row plan 0.10 600,300,,99; } > "$T/builds/s2c/cost.csv"
R=$(call plan "$T/builds/s2c/plan-run.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S2 a blank token cell adds 0: rc=$R order=$(norder)"

# =============================================================================
# S3 — stage-day scope trips alone, for a lane call outside any build
# =============================================================================
reset; settings '{"budget.stage.triage.day_usd":"10"}'; spend testproj.triage 10 4
R=$(call triage "$T/lane/out.txt")
[ "$R" = 74 ] && ok || bad "S3 rc=$R, want 74: $(head -2 "$T/err")"
[ "$(norder)" = 0 ] && ok || bad "S3 claude invoked"
grep -q '^AGENT_CALL_REFUSED budget-stage-day triage project=testproj stage=triage usd=10/10' <<<"$(line1 "$T/lane/out.txt")" \
  && ok || bad "S3 \$OUT: $(line1 "$T/lane/out.txt")"
grep -q '^AGENT_CALL_REFUSED budget-stage-day triage' <<<"$(line1 "$T/lane/out.txt.err")" && ok || bad "S3 \$OUT.err: $(line1 "$T/lane/out.txt.err")"
[ -z "$(find "$T" -name BUDGET_STOP 2>/dev/null)" ] && ok || bad "S3 a BUDGET_STOP marker was written for a day refusal"
[ "$(grep -c ',refused,.*refused:budget-stage-day' "$T/logs/cost.csv" 2>/dev/null)" = 1 ] && ok || bad "S3 refused rows: $(cat "$T/logs/cost.csv" 2>/dev/null)"
[ "$(nalerts budget-stage-day)" = 1 ] && ok || bad "S3 alert lines $(nalerts budget-stage-day), want 1"
grep -q 'budget-stage-day' "$T/logs/failovers.log" && ok || bad "S3 no failovers line"
R=$(call triage "$T/lane/out.txt")
[ "$R" = 74 ] && [ "$(nalerts budget-stage-day)" = 1 ] && ok || bad "S3 second refusal: rc=$R alerts=$(nalerts budget-stage-day), want 74 and 1"
reset; settings '{"budget.stage.triage.day_calls":"3"}'; spend testproj.triage 1 5 3
R=$(call triage "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S3 billed calls 2 < 3 must run: rc=$R $(line1 "$T/lane/out.txt")"
reset; settings '{"budget.stage.triage.day_calls":"3"}'; spend testproj.triage 1 5 1 1
R=$(call triage "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q 'calls=3/3' <<<"$(line1 "$T/lane/out.txt")" && ok || bad "S3 billed calls 3 >= 3: rc=$R $(line1 "$T/lane/out.txt")"

# =============================================================================
# S4 — project-day scope trips alone; another project runs
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"50"}'; spend testproj 50
R=$(call lead-review "$T/lane/out.txt")
[ "$R" = 74 ] && [ "$(norder)" = 0 ] && ok || bad "S4 rc=$R order=$(norder)"
grep -q '^AGENT_CALL_REFUSED budget-project-day lead-review project=testproj usd=50/50' <<<"$(line1 "$T/lane/out.txt")" \
  && ok || bad "S4 \$OUT: $(line1 "$T/lane/out.txt")"
reset; settings '{"budget.project.testproj.day_usd":"50"}'; spend testproj 50; spend otherproj 50
R=$(PROJ=otherproj call lead-review "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S4 otherproj refused: rc=$R $(line1 "$T/lane/out.txt")"

# =============================================================================
# S5 — research / Archie: no stage row, the _default rows cap it
# =============================================================================
reset; settings '{"budget.stage._default.day_usd":"5"}'; spend testproj.research 5
R=$(call research "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED budget-stage-day research ' <<<"$(line1 "$T/lane/out.txt")" \
  && ok || bad "S5 _default day_usd: rc=$R $(line1 "$T/lane/out.txt")"
reset; settings '{}'; spend testproj.research 5
R=$(call research "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S5 no _default row: rc=$R"
reset; settings '{"budget.stage._default.max_calls":"0"}'; seed s5
R=$(call research "$T/builds/s5/research-run.txt")
[ "$R" = 74 ] && grep -q '^budget_stop research max_calls calls=0 max_calls=0 ' <<<"$(line1 "$T/builds/s5/BUDGET_STOP")" \
  && ok || bad "S5 build research via _default.max_calls=0: rc=$R $(line1 "$T/builds/s5/BUDGET_STOP")"
# the specific row wins over _default, and its `off` unarms it outright
reset; settings '{"budget.stage._default.max_calls":"0","budget.stage.research.max_calls":"off"}'; seed s5b
R=$(call research "$T/builds/s5b/research-run.txt")
[ "$R" = 0 ] && ok || bad "S5 specific off must win over _default: rc=$R"

# =============================================================================
# S6 — the tightest wins
# =============================================================================
nine() { local a=(); for _ in 1 2 3 4 5 6 7 8 9; do a+=(execute:0.10); done; seed "$1" "${a[@]}"; }
reset; settings '{"budget.stage.execute.max_calls":"10","budget.project.testproj.day_usd":"100"}'; nine s6a; spend testproj 100
R=$(call execute "$T/builds/s6a/execute-run.txt")
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED budget-project-day execute ' <<<"$(line1 "$T/builds/s6a/execute-run.txt")" \
  && ok || bad "S6a rc=$R $(line1 "$T/builds/s6a/execute-run.txt")"
[ -e "$T/builds/s6a/BUDGET_STOP" ] && bad "S6a marker written for a project-day refusal" || ok
reset; settings '{"budget.stage.execute.max_calls":"9","budget.project.testproj.day_usd":"100"}'; nine s6b; spend testproj 120
R=$(call execute "$T/builds/s6b/execute-run.txt")
# project-day is further over (120/100 vs 9/9), but the build-stage overrun is
# terminal and must not be traded for a deferral that re-offers a fresh build.
L=$(line1 "$T/builds/s6b/BUDGET_STOP")
[ "$R" = 74 ] && grep -q '^budget_stop execute max_calls calls=9 max_calls=9 ' <<<"$L" && ok || bad "S6b build-stage must win over a more-over day scope: rc=$R $L $(line1 "$T/builds/s6b/execute-run.txt")"
grep -q 'also over: project-day usd 120/100' <<<"$L" && ok || bad "S6b also-over missing: $L"
[ -e "$T/builds/s6b/BUDGET_DEFER" ] && bad "S6b a deferral marker for a terminal stop" || ok
reset; settings '{"budget.stage.execute.max_calls":"9","budget.project.testproj.day_usd":"100"}'; nine s6c; spend testproj 99
R=$(call execute "$T/builds/s6c/execute-run.txt")
[ "$R" = 74 ] && grep -q '^budget_stop execute max_calls calls=9 max_calls=9 ' <<<"$(line1 "$T/builds/s6c/BUDGET_STOP")" \
  && ok || bad "S6c build-stage must win: rc=$R $(line1 "$T/builds/s6c/BUDGET_STOP")"
reset; settings '{"budget.stage.execute.day_usd":"10","budget.project.testproj.day_usd":"100"}'; spend testproj.execute 20; spend testproj 110
R=$(call execute "$T/lane/out.txt")
L=$(line1 "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED budget-stage-day execute ' <<<"$L" && ok || bad "S6d stage-day must win: rc=$R $L"
grep -q 'also over: project-day usd 110/100' <<<"$L" && ok || bad "S6d also-over: $L"

# =============================================================================
# S7 — each scope independently; no spend read without a cap
# =============================================================================
reset; settings '{"budget.stage.plan.day_usd":"5"}'; spend testproj.plan 6
R=$(call plan "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED budget-stage-day ' <<<"$(line1 "$T/lane/out.txt")" && ok || bad "S7 stage-day only: rc=$R"
[ "$(nspend)" = 1 ] && grep -q 'llm-spend?.*stage=plan' "$T/req.log" && ok || bad "S7 spend reads $(nspend), want exactly one with stage=: $(cat "$T/req.log")"
reset; settings '{}'
R=$(call plan "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(nspend)" = 0 ] && ok || bad "S7 no rows: rc=$R spend reads=$(nspend), want 0 and 0"
reset; rm -f "$T/state/settings-cache.json"
R=$(call plan "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(nspend)" = 0 ] && ok || bad "S7 no cache: rc=$R spend reads=$(nspend)"

# =============================================================================
# S8 — finishes nothing mid-call
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"100"}'; spend testproj 90
R=$(MIDCALL_SPEND=150 call lead-review "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S8 the running call: rc=$R order=$(norder)"
grep -q 'the answer' "$T/lane/out.txt" && ok || bad "S8 output not intact: $(head -2 "$T/lane/out.txt")"
grep -q ',lead-review,claude,.*,0.01' "$T/logs/cost.csv" 2>/dev/null && ok || bad "S8 its cost row was not written"
R=$(call lead-review "$T/lane/out.txt")
[ "$R" = 74 ] && [ "$(norder)" = 1 ] && ok || bad "S8 the next call: rc=$R order=$(norder), want 74 and 1"
grep -q '^AGENT_CALL_REFUSED budget-project-day lead-review project=testproj usd=150/100' <<<"$(line1 "$T/lane/out.txt")" \
  && ok || bad "S8 next call \$OUT: $(line1 "$T/lane/out.txt")"
[ -s "$T/sig" ] && bad "S8 a signal reached the running call: $(cat "$T/sig")" || ok

# =============================================================================
# S9 — the launch gate stops new builds
# =============================================================================
GATES="$DIR/bin/lib/rb/gates.sh"
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$GATES" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "S9 no '# >>> budget launch gate' block in bin/lib/rb/gates.sh"
grep -n '# <<< tripwire paused skip\|# >>> budget launch gate\|Fly builder trial' "$GATES" | awk -F: '{print $2}' | tr '\n' ' ' > "$T/order9"
grep -q '^# <<< tripwire paused skip # >>> budget launch gate (BH-4489) # --- Fly builder trial' "$T/order9" \
  && ok || bad "S9 placement: $(cat "$T/order9")"
launch() { # launch [VAR=VAL ...] -> rc; RESULT to $T/s9/result, REACHED to $T/s9/reached
  rm -rf "$T/s9"; mkdir -p "$T/s9/build"
  ( export REQ_LOG="$T/req.log" SPEND_DIR="$T/spend" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           HARNESS_SECRET=testsecret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 "$@"
    bash -c '
      set -uo pipefail
      PROJECT=testproj; KEY=TP-1; BUILD="$HARNESS/s9/build"
      STAMP() { date -u +%FT%TZ; }
      RESULT() { printf "%s\n" "$*" > "$HARNESS/s9/result"; }
      . "$HARNESS/bin/jobs-client.sh"
      . "$2"
      . "$1"
      echo REACHED > "$HARNESS/s9/reached"' _ "$T/launch.sh" "$LIB" )
  echo $?
}
plf_late() { awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf9.sh"; bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf9.sh" "$1"; }
reset; settings '{"budget.project.testproj.day_usd":"100"}'; spend testproj 100
R=$(launch)
[ "$R" = 3 ] && ok || bad "S9 over: rc=$R, want 3"
grep -q '^BUILD_DEFERRED budget-project-day project=testproj usd=100/100 ' "$T/s9/result" 2>/dev/null && ok || bad "S9 RESULT: $(cat "$T/s9/result" 2>/dev/null)"
[ -e "$T/s9/reached" ] && bad "S9 the Fly enqueue was reached over the cap" || ok
reset; settings '{"budget.project.testproj.day_usd":"100"}'; spend testproj 99.99
R=$(launch)
[ "$R" = 0 ] && [ -e "$T/s9/reached" ] && ok || bad "S9 under the cap: rc=$R"
reset; settings '{"budget.project.testproj.day_usd":"100"}'
R=$(launch SPEND_FAKE=down)
[ "$R" = 3 ] && [ ! -e "$T/s9/reached" ] && ok || bad "S9 unreadable spend must defer (fail closed): rc=$R"
grep -q '^BUILD_DEFERRED budget-cap-unreadable launch budget-total-unreadable:project-day ' "$T/s9/result" 2>/dev/null && ok || bad "S9 unreadable RESULT: $(cat "$T/s9/result" 2>/dev/null)"
[ "$(grep -c 'budget launch gate' "$T/s9/build/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "S9 unreadable: pipeline.log $(cat "$T/s9/build/pipeline.log" 2>/dev/null)"
# A later build stage's stage-day cap is over: the launch defers on it.
reset; settings '{"budget.stage.review.day_usd":"2"}'; spend testproj.review 3
R=$(launch)
[ "$R" = 3 ] && [ ! -e "$T/s9/reached" ] && ok || bad "S9 review stage-day over must defer the launch: rc=$R"
grep -q '^BUILD_DEFERRED budget-stage-day project=testproj stage=review usd=3/2 calls=1/- ' "$T/s9/result" 2>/dev/null && ok || bad "S9 stage-day RESULT: $(cat "$T/s9/result" 2>/dev/null)"
[ "$(plf_late 'BUILD_DEFERRED budget-stage-day project=testproj stage=review usd=3/2 calls=1/- — re-offered next tick')" = 0 ] && ok || bad "S9 pool counts the launch-gate stage-day deferral"
reset; settings '{"budget.stage.qa.day_calls":"4"}'; spend testproj.qa 1 5
R=$(launch)
[ "$R" = 3 ] && grep -q '^BUILD_DEFERRED budget-stage-day project=testproj stage=qa usd=1/- calls=5/4 ' "$T/s9/result" 2>/dev/null \
  && ok || bad "S9 qa day_calls over: rc=$R $(cat "$T/s9/result" 2>/dev/null)"
# Non-vacuity: a non-build stage over its day cap does not stop a build.
reset; settings '{"budget.stage.triage.day_usd":"2"}'; spend testproj.triage 3
R=$(launch)
[ "$R" = 0 ] && [ -e "$T/s9/reached" ] && ok || bad "S9 a triage stage-day cap must not stop a build: rc=$R"
reset; settings '{"budget.stage.fix.day_usd":"junk"}'
R=$(launch)
[ "$R" = 3 ] && grep -q '^BUILD_DEFERRED budget-cap-unreadable launch cap-unreadable:budget.stage.fix.day_usd ' "$T/s9/result" 2>/dev/null \
  && ok || bad "S9 a junk later-stage cap must defer the launch: rc=$R $(cat "$T/s9/result" 2>/dev/null)"

# Two consecutive attempts of ONE ticket under a review stage-day cap (refute
# finding 1). Each attempt is a fresh build dir, as a triage re-offer or a pool
# requeue is: launch gate, then plan, execute and review through the real
# agent-call. Attempt 1 buys plan and execute, and its own spend (mirrored to
# D1) carries review over the cap, so review defers. Attempt 2 must buy nothing.
attempt() { # attempt <n> -> "launch=<rc> plan=<rc> execute=<rc> review=<rc>"
  local b="$T/builds/s9t-$1" r rp="-" re="-" rr="-"
  r=$(launch)
  if [ "$r" = 0 ]; then
    rp=$(call plan "$b/plan-run.txt")
    re=$(call execute "$b/execute-run.txt")
    spend testproj.review 2.5 4
    rr=$(call review "$b/review-run.txt")
  fi
  echo "launch=$r plan=$rp execute=$re review=$rr"
}
reset; settings '{"budget.stage.review.day_usd":"2","budget.stage.plan.day_usd":"1000","budget.stage.execute.day_usd":"1000"}'; spend testproj.review 1.5 3
A1=$(attempt 1); N1=$(norder)
[ "$A1" = "launch=0 plan=0 execute=0 review=74" ] && [ "$N1" = 2 ] && ok || bad "S9 attempt 1: $A1 order=$N1, want plan+execute bought and review refused"
grep -q '^AGENT_CALL_REFUSED budget-stage-day review ' "$T/builds/s9t-1/review-run.txt" 2>/dev/null && ok || bad "S9 attempt 1 review: $(line1 "$T/builds/s9t-1/review-run.txt")"
A2=$(attempt 2); N2=$(norder)
[ "$A2" = "launch=3 plan=- execute=- review=-" ] && ok || bad "S9 attempt 2 must stop at launch: $A2"
[ "$N2" = "$N1" ] && ok || bad "S9 attempt 2 bought $((N2 - N1)) call(s) on a re-offer under a review stage-day cap"
{ [ -e "$T/builds/s9t-2/plan-run.txt" ] || [ -e "$T/builds/s9t-2/execute-run.txt" ]; } && bad "S9 attempt 2 reached plan or execute" || ok
reset; settings '{"budget.project.testproj.day_usd":"0"}'; spend testproj 1; touch "$T/flags/budget-stop-off"
R=$(launch)
[ "$R" = 0 ] && [ -e "$T/s9/reached" ] && ok || bad "S9 budget-stop-off: rc=$R"

# =============================================================================
# S10 — CC() defers on a day cap; the pool does not count it
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
mkdir -p "$T/h/bin"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$AC_LINE" > "$5"
exit "${AC_RC:-74}"
STUB
chmod +x "$T/h/bin/agent-call.sh"
cc() { # cc <case> <stage> [VAR=VAL ...]
  local c="$1" st="$2"; shift 2
  rm -rf "$T/cc/$c"; mkdir -p "$T/cc/$c/build"
  ( export SINK="$T/cc/$c" BUILD="$T/cc/$c/build" ST="$st" "$@"
    bash -c '
      set -uo pipefail
      HARNESS="'"$T"'/h"; PROJECT=testproj; KEY=TP-1; CG_ORIENT=x
      STAMP() { date -u +%FT%TZ; }
      BB() { printf "%s|%s\n" "$1" "${3:-}" >> "$SINK/bb"; }
      RESULT() { printf "%s\n" "$*" >> "$SINK/result"; }
      . "'"$T"'/cc.sh"
      CC "$ST" model 60 "$BUILD/$ST-run.txt" "PROMPT"
      echo "returned $?" > "$SINK/returned"' )
  echo $?
}
R=$(cc c1 plan AC_LINE="AGENT_CALL_REFUSED budget-project-day plan project=testproj usd=100/100")
[ "$R" = 3 ] && ok || bad "S10 project-day: rc=$R, want 3"
grep -q '^BUILD_DEFERRED budget-project-day plan project=testproj usd=100/100' "$T/cc/c1/result" 2>/dev/null && ok || bad "S10 RESULT: $(cat "$T/cc/c1/result" 2>/dev/null)"
[ -e "$T/cc/c1/build/BUDGET_STOP" ] && bad "S10 a terminal marker on a deferral" || ok
# BUDGET_DEFER carries the deferral out of a backgrounded lens (the parallel
# lens path is driven end to end in tests/parallel-lenses-test.sh section 8)
[ "$(head -1 "$T/cc/c1/build/BUDGET_DEFER" 2>/dev/null)" = "budget-project-day plan project=testproj usd=100/100" ] \
  && ok || bad "S10 BUDGET_DEFER: $(cat "$T/cc/c1/build/BUDGET_DEFER" 2>/dev/null)"
R=$(cc c2 review AC_LINE="AGENT_CALL_REFUSED budget-stage-day review project=testproj stage=review usd=3/2 calls=1/-")
[ "$R" = 3 ] && grep -q '^BUILD_DEFERRED budget-stage-day review' "$T/cc/c2/result" 2>/dev/null && ok || bad "S10 stage-day: rc=$R $(cat "$T/cc/c2/result" 2>/dev/null)"
R=$(cc c3 fix AC_LINE="AGENT_CALL_REFUSED budget-cap-unreadable fix budget-total-unreadable:project-day")
[ "$R" = 3 ] && grep -q '^BUILD_DEFERRED budget-cap-unreadable fix' "$T/cc/c3/result" 2>/dev/null && ok || bad "S10 unreadable: rc=$R $(cat "$T/cc/c3/result" 2>/dev/null)"
R=$(cc c4 plan AC_LINE="AGENT_CALL_REFUSED llm-gate usd-cap-day lane")
[ "$R" = 0 ] && [ "$(cat "$T/cc/c4/returned" 2>/dev/null)" = "returned 74" ] && ok || bad "S10 another 74 must pass through: rc=$R $(cat "$T/cc/c4/returned" 2>/dev/null)"
R=$(cc c5 plan AC_RC=0 AC_LINE="AGENT_CALL_REFUSED budget-project-day plan project=testproj usd=1/1")
[ "$R" = 0 ] && [ "$(cat "$T/cc/c5/returned" 2>/dev/null)" = "returned 0" ] && ok || bad "S10 rc 0 must not defer: rc=$R"
{ [ -e "$T/cc/c4/build/BUDGET_DEFER" ] || [ -e "$T/cc/c5/build/BUDGET_DEFER" ]; } && bad "S10 BUDGET_DEFER without a budget deferral" || ok
# A build already deferred by a sibling call (a lens's subshell) refuses the
# next CC() BEFORE agent-call is bought, and the RESULT is the deferral.
rm -rf "$T/cc/c6"; mkdir -p "$T/cc/c6/build"
printf 'budget-stage-day review project=testproj stage=review usd=3/2\n' > "$T/cc/c6/build/BUDGET_DEFER"
( export SINK="$T/cc/c6" BUILD="$T/cc/c6/build" AC_RC=0 AC_LINE=ok
  bash -c '
    set -uo pipefail
    HARNESS="'"$T"'/h"; PROJECT=testproj; KEY=TP-1; CG_ORIENT=x
    STAMP() { date -u +%FT%TZ; }
    BB() { :; }
    RESULT() { printf "%s\n" "$*" >> "$SINK/result"; }
    . "'"$T"'/cc.sh"
    CC fix model 60 "$BUILD/fix-run.txt" "PROMPT"
    echo "returned $?" > "$SINK/returned"' ); R=$?
[ "$R" = 3 ] && ok || bad "S10 a pre-existing BUDGET_DEFER must defer the next call: rc=$R"
[ -e "$T/cc/c6/build/fix-run.txt" ] && bad "S10 agent-call was bought on a deferred build" || ok
[ "$(cat "$T/cc/c6/result" 2>/dev/null)" = "BUILD_DEFERRED budget-stage-day review project=testproj stage=review usd=3/2" ] \
  && ok || bad "S10 pre-check RESULT: $(cat "$T/cc/c6/result" 2>/dev/null)"
awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf.sh"
plf() { bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf.sh" "$1"; }
[ "$(plf 'BUILD_DEFERRED budget-project-day plan project=testproj usd=100/100')" = 0 ] && ok || bad "S10 pool counts a project-day deferral"
[ "$(plf 'BUILD_DEFERRED budget-stage-day review project=testproj stage=review usd=3/2')" = 0 ] && ok || bad "S10 pool counts a stage-day deferral"
[ "$(plf 'BUILD_DEFERRED budget-project-day project=testproj usd=100/100 — re-offered next tick')" = 0 ] && ok || bad "S10 pool counts the launch-gate deferral"
[ "$(plf 'BUILD_DEFERRED budget-cap-unreadable fix budget-total-unreadable:project-day')" = 1 ] && ok || bad "S10 an outage must count"
[ "$(plf 'BUILD_DEFERRED wip-limit 2 reached')" = 1 ] && ok || bad "S10 non-vacuity: wip-limit"

# =============================================================================
# S11 — fail closed inside a build, open outside
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"100"}'; seed s11
R=$(call plan "$T/builds/s11/plan-run.txt" SPEND_FAKE=down)
[ "$R" = 74 ] && [ "$(norder)" = 0 ] && ok || bad "S11 in a build: rc=$R order=$(norder)"
[ "$(line1 "$T/builds/s11/plan-run.txt")" = "AGENT_CALL_REFUSED budget-cap-unreadable plan budget-total-unreadable:project-day" ] \
  && ok || bad "S11 \$OUT: $(line1 "$T/builds/s11/plan-run.txt")"
[ -e "$T/builds/s11/BUDGET_STOP" ] && bad "S11 an outage wrote the terminal marker" || ok
reset; settings '{"budget.project.testproj.day_usd":"100"}'
R=$(call plan "$T/lane/out.txt" SPEND_FAKE=down)
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S11 outside a build must run: rc=$R $(line1 "$T/lane/out.txt")"
[ "$(grep -c 'allowed' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "S11 outside: ALERTS $(cat "$T/logs/ALERTS.log")"
R=$(call plan "$T/lane/out.txt" SPEND_FAKE=down)
[ "$R" = 0 ] && [ "$(grep -c 'allowed' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "S11 second call same day: rc=$R alerts=$(grep -c allowed "$T/logs/ALERTS.log")"
reset; mkdir -p "$T/state"; printf '{"fetched_at":%s,"values":' "$(date -u +%s)" > "$T/state/settings-cache.json"
R=$(call plan "$T/lane/out.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S11 corrupt settings outside a build must run: rc=$R"
[ "$(grep -c 'budget-unreadable' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "S11 corrupt settings: ALERTS $(cat "$T/logs/ALERTS.log")"

# =============================================================================
# S12 — adversarial negatives: each runs, no marker, no refused row
# =============================================================================
neg() { # neg <label> <stage> <out> [VAR=VAL ...]
  local l="$1" st="$2" out="$3"; shift 3
  local r; r=$(call "$st" "$out" "$@")
  [ "$r" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S12 $l: rc=$r order=$(norder) $(line1 "$out")"
  [ -z "$(find "$T/builds" -name BUDGET_STOP 2>/dev/null)" ] && ok || bad "S12 $l wrote a marker"
  grep -q ',refused,' "$T/logs/cost.csv" 2>/dev/null && bad "S12 $l wrote a refused row" || ok
}
reset; settings '{"budget.stage.review.day_usd":"1"}'; spend testproj.review 5; spend testproj.plan 5
neg other-stage plan "$T/lane/out.txt"
reset; settings '{"budget.project.project-3.day_usd":"0"}'; spend testproj 5
neg other-project plan "$T/lane/out.txt"
reset; settings '{"budget.stage.plan.day_calls":"1"}'; spend testproj.plan 0 5 5
neg refused-only plan "$T/lane/out.txt"
reset; settings '{"budget.stage.plan.day_calls":"1"}'; spend testproj.plan 0 5 3 2
neg refused-and-settled plan "$T/lane/out.txt"
reset; settings '{"budget.stage.plan.day_usd":"10"}'; spend testproj.plan 9.99
neg one-cent-under plan "$T/lane/out.txt"
reset; settings '{"budget.stage.plan.day_usd":"0","budget.project.testproj.day_usd":"0","budget.stage.plan.max_calls":"0","budget.stage._default.max_calls":"0"}'
touch "$T/flags/budget-stop-off"; seed n6
neg kill-switch plan "$T/builds/n6/plan-run.txt"
[ "$(nspend)" = 0 ] && ok || bad "S12 kill switch still read spend: $(nspend)"

# =============================================================================
# S13 — key legality
# =============================================================================
reset; settings '{"budget.stage.Orc_Proof.day_usd":"0"}'; spend testproj.Orc_Proof 1
R=$(call Orc_Proof "$T/lane/out.txt")
[ "$R" = 0 ] && ok || bad "S13 an illegal-key row must never be read: rc=$R $(line1 "$T/lane/out.txt")"
reset; settings '{"budget.stage._default.day_usd":"1"}'; spend testproj.Orc_Proof 1
R=$(call Orc_Proof "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED budget-stage-day Orc_Proof ' <<<"$(line1 "$T/lane/out.txt")" && ok || bad "S13 Orc_Proof via _default: rc=$R $(line1 "$T/lane/out.txt")"
# a stage name the spend query cannot carry is no stage-day scope at all, never
# an "unreadable" one: inside a build that would defer the build forever
reset; settings '{"budget.stage._default.day_usd":"1"}'; seed s13
R=$(call 'Orc:Proof' "$T/builds/s13/orc-run.txt")
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "S13 Orc:Proof in a build must run: rc=$R $(line1 "$T/builds/s13/orc-run.txt")"
LONGP=p$(printf 'x%.0s' $(seq 1 49))
reset; settings "{\"budget.project.$LONGP.day_usd\":\"0\",\"budget.project._default.day_usd\":\"10\"}"; spend "$LONGP" 10
R=$(PROJ="$LONGP" call plan "$T/lane/out.txt")
[ "$R" = 74 ] && grep -q "^AGENT_CALL_REFUSED budget-project-day plan project=$LONGP usd=10/10" <<<"$(line1 "$T/lane/out.txt")" \
  && ok || bad "S13 50-char project via _default: rc=$R $(line1 "$T/lane/out.txt")"
reset; settings "{\"budget.project.$LONGP.day_usd\":\"0\"}"; spend "$LONGP" 10
R=$(PROJ="$LONGP" call plan "$T/lane/out.txt")
[ "$R" = 0 ] && ok || bad "S13 the over-long key must not be read: rc=$R"

echo "budget-caps-scopes.bh-4489-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
