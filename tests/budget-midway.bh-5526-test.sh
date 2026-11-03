#!/bin/bash
# tests/budget-midway.bh-5526-test.sh — a day spend cap never stops a ticket
# midway (BH-5526, slice C0). The ticket boundary is the build launch gate in
# bin/lib/rb/gates.sh: it refuses a NEW build over a day cap, and when it lets
# one through it writes $BUILD/ADMITTED. Every call inside an admitted build
# dir runs to the end of the ticket, whatever a day cap says.
#
#   M1  bs_gate: project-day cap over inside an admitted build -> allowed, one
#       pipeline.log line per build
#   M2  bs_gate: stage-day cap over at review inside an admitted build -> allowed
#   M3  bs_gate: day spend unreadable inside an admitted build -> allowed (not 3)
#   M4  the REAL bin/agent-call.sh: LLM_USD_CAP_DAY over, $OUT in an admitted
#       build -> the vendor is called; the same call un-admitted -> rc 74
#   M5  the launch gate block: fly-pool LLM_USD_CAP_DAY over -> BUILD_DEFERRED
#       with the spend, one alert per (project, day), no ADMITTED; a resume of
#       an admitted dir passes; under the cap ADMITTED is written; the pool
#       reads the deferral as the lane's, not the ticket's
#   M6  negatives that must still refuse: an ended ticket (RESULT present), a
#       lane other than fly-pool (postmerge-qa) in an admitted dir; and the
#       in-ticket log line only when a cap is set
#
# Drives the real libs, the real agent-call and the real jobs client against a
# fake curl worker; asserts on artifacts only.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/budget-midway.bh-5526-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/budget-stop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- fixture -----------------------------------------------------------------
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/builds" "$T/bin/lib/jobs" "$T/logs" "$T/state"
# The launch gate's closure carries budget-stop, llm-gate and lane-gate.
for f in bin/jobs-client.sh bin/alert-line.sh bin/lib/rb/gates.sh; do
  scratch_install_closure "$f" "$T" >/dev/null || { echo "cannot install the closure of $f"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
echo '{"lanes":[]}' > "$T/budgets.json"
echo '{"version":1,"lanes":[]}' > "$T/lanes.json"
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
# The worker: every llm-spend question answers $SPEND_USD (3 calls); SPEND_FAKE
# =down is a transport failure. Every other path 404.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$REQ_LOG"
case "$URL" in
  */api/metrics/llm-spend\?*)
    [ "${SPEND_FAKE:-}" = down ] && exit 7
    printf '{"usd":%s,"calls":3,"refused":0,"settled":0}\n200\n' "${SPEND_USD:-0}" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
settings() { jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/req.log"
  rm -f "$T/logs/cost.csv" "$T/flags/"*; rm -rf "$T/builds" "$T/s5"; mkdir -p "$T/builds"
  echo '{}' > "$T/state/settings-cache.json"; settings '{}'
}
admit() { mkdir -p "$T/builds/$1"; echo "2026-10-08T00:00:00Z K-1" > "$T/builds/$1/ADMITTED"; }
ENVS=(REQ_LOG="$T/req.log" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T"
      HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 LANE_REGISTRY="$T/lanes.json")
# gate <stage> <out> [VAR=VAL ...] -> "rc|BS_REFUSE"; bs_gate run twice when TWICE=1
gate() {
  local st="$1" out="$2"; shift 2
  mkdir -p "$(dirname "$out")"
  ( export "${ENVS[@]}" "$@"
    bash -c '
      set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$1"
      [ "${TWICE:-0}" = 1 ] && bs_gate testproj "$2" "$3"
      bs_gate testproj "$2" "$3"; rc=$?
      printf "%s|%s" "$rc" "$BS_REFUSE"' _ "$LIB" "$st" "$out" 2>/dev/null )
}
# call <stage> <out> [VAR=VAL ...] -> the rc of the REAL bin/agent-call.sh
call() {
  local st="$1" out="$2"; shift 2
  mkdir -p "$(dirname "$out")"
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID LLM_GATE_IN_TICKET
    export "${ENVS[@]}" ORDER_SINK="$T/order" \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=0 \
           AGENT_CALL_LANE=fly-pool IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$st" testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
norder() { grep -c . "$T/order"; }
nallowed() { grep -c 'call ALLOWED (BH-5526)' "$1" 2>/dev/null; }

# =============================================================================
# M1 — project-day cap over, inside an admitted build: allowed, logged once
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"1"}'; admit testproj-K-1
R=$(gate execute "$T/builds/testproj-K-1/execute.txt" SPEND_USD=5 TWICE=1)
[ "$R" = "0|" ] && ok || bad "M1 admitted execute over project-day cap: got '$R', want '0|'"
[ "$(nallowed "$T/builds/testproj-K-1/pipeline.log")" = 1 ] && ok \
  || bad "M1 want exactly one ALLOWED line after two calls: $(cat "$T/builds/testproj-K-1/pipeline.log" 2>/dev/null)"
grep -q 'budget-project-day execute project=testproj usd=5/1' "$T/builds/testproj-K-1/pipeline.log" 2>/dev/null && ok \
  || bad "M1 the ALLOWED line must name the spend and cap: $(cat "$T/builds/testproj-K-1/pipeline.log" 2>/dev/null)"
[ ! -e "$T/builds/testproj-K-1/BUDGET_DEFER" ] && ok || bad "M1 BUDGET_DEFER written"

# =============================================================================
# M2 — stage-day cap over at review, inside an admitted build: allowed
# =============================================================================
reset; settings '{"budget.stage.review.day_usd":"1"}'; admit testproj-K-2
R=$(gate review "$T/builds/testproj-K-2/review.txt" SPEND_USD=5)
[ "$R" = "0|" ] && ok || bad "M2 admitted review over stage-day cap: got '$R'"
[ "$(nallowed "$T/builds/testproj-K-2/pipeline.log")" = 1 ] && ok || bad "M2 no ALLOWED line"

# =============================================================================
# M3 — day spend unreadable, inside an admitted build: allowed, not rc 3
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"1"}'; admit testproj-K-3
R=$(gate execute "$T/builds/testproj-K-3/execute.txt" SPEND_FAKE=down)
[ "$R" = "0|" ] && ok || bad "M3 admitted + unreadable spend: got '$R', want '0|'"
grep -q 'budget-cap-unreadable execute' "$T/builds/testproj-K-3/pipeline.log" 2>/dev/null && ok \
  || bad "M3 the ALLOWED line must name the unreadable reason: $(cat "$T/builds/testproj-K-3/pipeline.log" 2>/dev/null)"

# =============================================================================
# M4 — the REAL agent-call, fly-pool LLM_USD_CAP_DAY over, admitted dir
# =============================================================================
reset; admit testproj-K-1
R=$(call execute "$T/builds/testproj-K-1/out.txt" LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 0 ] && ok || bad "M4 admitted execute over LLM_USD_CAP_DAY: rc=$R, want 0 ($(head -1 "$T/builds/testproj-K-1/out.txt" 2>/dev/null))"
[ "$(norder)" = 1 ] && ok || bad "M4 the vendor was not called (order=$(norder))"
grep -q AGENT_CALL_REFUSED "$T/builds/testproj-K-1/out.txt" 2>/dev/null && bad "M4 AGENT_CALL_REFUSED in \$OUT" || ok
# The control: the same call without ADMITTED is refused before the vendor.
reset; mkdir -p "$T/builds/testproj-K-1"
R=$(call execute "$T/builds/testproj-K-1/out.txt" LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 74 ] && ok || bad "M4 control (not admitted): rc=$R, want 74"
grep -q '^AGENT_CALL_REFUSED llm-gate usd-cap-day lane spent=\$5 cap=\$1' "$T/builds/testproj-K-1/out.txt" 2>/dev/null && ok \
  || bad "M4 control: $(head -1 "$T/builds/testproj-K-1/out.txt" 2>/dev/null)"
[ "$(norder)" = 0 ] && ok || bad "M4 control: the vendor was called"

# =============================================================================
# M5 — the launch gate block in bin/lib/rb/gates.sh
# =============================================================================
GATES="$DIR/bin/lib/rb/gates.sh"
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$GATES" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "M5 no '# >>> budget launch gate' block"
# launch <build-subdir> [VAR=VAL ...] -> rc; RESULT to <build>/RESULT, REACHED to <build>/reached
launch() {
  local b="$T/s5/$1"; shift
  mkdir -p "$b"
  ( export "${ENVS[@]}" BUILD="$b" \
           RB_GATES_D="$DIR/bin/lib/rb/gates.d" "$@"
    bash -c '
      set -uo pipefail
      PROJECT=testproj; KEY=K-5
      STAMP() { date -u +%FT%TZ; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      . "$HARNESS/bin/jobs-client.sh"
      . "$1"
      echo REACHED > "$BUILD/reached"' _ "$T/launch.sh" 2>/dev/null )
  echo $?
}
reset
R=$(launch a LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 3 ] && ok || bad "M5 fresh build over the fly-pool cap: rc=$R, want 3"
grep -q '^BUILD_DEFERRED usd-cap-day .*spent=\$5 cap=\$1' "$T/s5/a/RESULT" 2>/dev/null && ok || bad "M5 RESULT: $(cat "$T/s5/a/RESULT" 2>/dev/null)"
[ ! -e "$T/s5/a/ADMITTED" ] && ok || bad "M5 ADMITTED written on a refused launch"
[ ! -e "$T/s5/a/reached" ] && ok || bad "M5 the build went past the gate over the cap"
grep -q 'usd-cap-day' "$T/s5/a/pipeline.log" 2>/dev/null && ok || bad "M5 no pipeline.log line"
M5_RESULT=$(cat "$T/s5/a/RESULT" 2>/dev/null)
[ "$(grep -c 'spent=\$5 cap=\$1' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "M5 want one ALERTS line naming the spend: $(cat "$T/logs/ALERTS.log")"
R=$(launch b LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 3 ] && [ "$(grep -c 'spent=\$5 cap=\$1' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "M5 second refusal same day: rc=$R alerts=$(grep -c . "$T/logs/ALERTS.log")"
# A resume of an admitted ticket is in progress: the launch caps do not apply.
mkdir -p "$T/s5/c"; echo "2026-10-08T00:00:00Z K-5" > "$T/s5/c/ADMITTED"
R=$(launch c LLM_USD_CAP_DAY=1 SPEND_USD=5 RESUME_BUILD="$T/s5/c")
[ "$R" = 0 ] && [ -e "$T/s5/c/reached" ] && ok || bad "M5 resume of an admitted dir: rc=$R"
# A resume of a dir that was never admitted is checked like a fresh start.
R=$(launch d LLM_USD_CAP_DAY=1 SPEND_USD=5 RESUME_BUILD="$T/s5/d")
[ "$R" = 3 ] && ok || bad "M5 resume of an un-admitted dir must be checked: rc=$R"
# Under the cap: admitted.
R=$(launch e LLM_USD_CAP_DAY=1 SPEND_USD=0)
[ "$R" = 0 ] && [ -e "$T/s5/e/reached" ] && ok || bad "M5 under the cap: rc=$R"
grep -q ' K-5$' "$T/s5/e/ADMITTED" 2>/dev/null && ok || bad "M5 ADMITTED not written under the cap: $(cat "$T/s5/e/ADMITTED" 2>/dev/null)"
# The budget-stop project-day refusal at launch alerts once with the spend too.
reset; settings '{"budget.project.testproj.day_usd":"1"}'
R=$(launch f SPEND_USD=5)
[ "$R" = 3 ] && [ ! -e "$T/s5/f/ADMITTED" ] && ok || bad "M5 project-day launch refusal: rc=$R"
[ "$(grep -c 'budget-project-day project=testproj usd=5/1' "$T/logs/ALERTS.log")" = 1 ] && ok \
  || bad "M5 project-day launch refusal must alert with the spend: $(cat "$T/logs/ALERTS.log")"
# The pool reads the cap deferral as the lane's condition, not the ticket's.
awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf.sh"
R=$(bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf.sh" "$M5_RESULT")
[ "$R" = 0 ] && ok || bad "M5 pool_lane_failure counts the usd-cap-day launch deferral against the ticket"

# =============================================================================
# M6 — negatives: these still refuse
# =============================================================================
reset; settings '{"budget.project.testproj.day_usd":"1"}'
R=$(gate triage "$T/lane/triage.txt" SPEND_USD=5)
[ "${R%%|*}" = 2 ] && ok || bad "M6 outside a build: got '$R', want rc 2"
mkdir -p "$T/builds/testproj-K-9"
R=$(gate execute "$T/builds/testproj-K-9/x.txt" SPEND_USD=5)
[ "${R%%|*}" = 2 ] && ok || bad "M6 un-admitted build: got '$R', want rc 2"
R=$(gate execute "$T/builds/testproj-K-9/x.txt" SPEND_FAKE=down)
[ "${R%%|*}" = 3 ] && ok || bad "M6 un-admitted build, unreadable: got '$R', want rc 3"
admit testproj-K-8
R=$(gate execute "$T/builds/testproj-K-9/x.txt" SPEND_USD=5)
[ "${R%%|*}" = 2 ] && ok || bad "M6 ADMITTED in a sibling dir only: got '$R', want rc 2"
reset; admit testproj-K-1
R=$(call execute "$T/builds/testproj-K-1/out.txt" LLM_LANE_ENABLED=0)
[ "$R" = 74 ] && grep -q '^AGENT_CALL_REFUSED llm-gate lane-disabled' "$T/builds/testproj-K-1/out.txt" 2>/dev/null && ok \
  || bad "M6 LLM_LANE_ENABLED=0 in an admitted dir: rc=$R $(head -1 "$T/builds/testproj-K-1/out.txt" 2>/dev/null)"
R=$(call execute "$T/lane/out.txt" LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 74 ] && ok || bad "M6 agent-call outside a build over LLM_USD_CAP_DAY: rc=$R, want 74"
# B1: an admitted dir whose ticket ENDED (RESULT present) is no longer in
# progress. Post-merge QA and replan-check write there; their day caps apply.
reset; settings '{"budget.project.testproj.day_usd":"1"}'; admit testproj-K-1
echo "PR_CREATED https://x/pull/1" > "$T/builds/testproj-K-1/RESULT"
R=$(gate qa-prod "$T/builds/testproj-K-1/qa-prod-run.txt" SPEND_USD=5)
[ "${R%%|*}" = 2 ] && ok || bad "M6 admitted dir with RESULT, project-day over: got '$R', want rc 2"
R=$(call replan "$T/builds/testproj-K-1/replan-run.txt" LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 74 ] && ok || bad "M6 fly-pool call into an ended admitted dir over LLM_USD_CAP_DAY: rc=$R, want 74"
# B1: another lane writing into an admitted, in-progress dir is its own start.
reset; settings '{"budget.project.testproj.day_usd":"1"}'; admit testproj-K-1
R=$(gate qa-prod "$T/builds/testproj-K-1/qa-prod-run.txt" SPEND_USD=5 AGENT_CALL_LANE=postmerge-qa)
[ "${R%%|*}" = 2 ] && ok || bad "M6 admitted dir, lane postmerge-qa, project-day over: got '$R', want rc 2"
reset; admit testproj-K-1
R=$(call qa-prod "$T/builds/testproj-K-1/qa-prod-run.txt" AGENT_CALL_LANE=postmerge-qa LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 74 ] && ok || bad "M6 admitted dir, lane postmerge-qa over LLM_USD_CAP_DAY: rc=$R, want 74"
[ "$(norder)" = 0 ] && ok || bad "M6 lane postmerge-qa: the vendor was called"
# N1: an in-ticket call with no cap set writes no "was not applied" line; with
# a cap set it writes one that names the cap.
reset; rm -rf "$T/state/lane-gate"; : > "$T/logs/lane-gate.log"; admit testproj-K-1
R=$(call execute "$T/builds/testproj-K-1/out.txt" SPEND_USD=5)
[ "$R" = 0 ] && ! grep -q 'was not applied' "$T/logs/lane-gate.log" && ok \
  || bad "M6 in-ticket call with no cap logged a cap that does not exist: rc=$R $(cat "$T/logs/lane-gate.log")"
reset; rm -rf "$T/state/lane-gate"; : > "$T/logs/lane-gate.log"; admit testproj-K-1
R=$(call execute "$T/builds/testproj-K-1/out.txt" LLM_USD_CAP_DAY=1 SPEND_USD=5)
[ "$R" = 0 ] && grep -q 'LLM_USD_CAP_DAY (lane \$1,.*was not applied' "$T/logs/lane-gate.log" && ok \
  || bad "M6 in-ticket call over a set cap: rc=$R, want one line naming the cap: $(cat "$T/logs/lane-gate.log")"
reset; settings '{"budget.stage.execute.max_calls":"1"}'; admit testproj-K-1
printf '%s\n%s\n' "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd" \
  "2026-10-08T00:00:00Z,box,testproj,execute,claude,m,0,1,1,1,0,0,0.10" > "$T/builds/testproj-K-1/cost.csv"
R=$(gate execute "$T/builds/testproj-K-1/x.txt")
[ "${R%%|*}" = 1 ] && [ -s "$T/builds/testproj-K-1/BUDGET_STOP" ] && ok || bad "M6 build-stage max_calls in an admitted dir must still stop: got '$R'"

echo "budget-midway.bh-5526: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
