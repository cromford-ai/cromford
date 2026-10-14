#!/bin/bash
# tests/spend-ceiling.bh-5526-test.sh — the runaway spend ceiling (BH-5526,
# slice C3). A lane has a hard ceiling per UTC day, the settings row
# `spend.ceiling.<lane>.day_usd`, seeded at 3x its p99 daily spend for a lane
# with 7 or more days of data. Over the ceiling, no NEW ticket, build or review
# starts on the lane; a ticket already admitted runs every stage to the end.
#
#   C1  the REAL agent-call, fly-pool over its ceiling, $OUT in an admitted
#       build: execute and review are both called, the ceiling is not read
#   C2  the same at $1000 and with the spend read down; an ENDED ticket
#       (RESULT present) is refused rc 74
#   C3  lead-review over its ceiling outside a build: rc 74, the refusal text,
#       one refused cost row, ONE alert for two refusals; the decision table
#       (9.99 / 10 / off / 0 / abc / no row / kill switch / read down)
#   C4  the launch gate block: a fresh build over the fly-pool ceiling is
#       BUILD_DEFERRED spend-ceiling, no ADMITTED, one lane alert and no
#       per-project llm-cap-launch alert, pool_lane_failure rc 0; a resume of
#       an admitted dir passes with no read; under the ceiling ADMITTED
#   C5  postmerge-qa inside an admitted dir checks its own ceiling: rc 74
#   S1  the REAL bin/spend-ceiling-seed.sh: rows only for lanes with 7+ days,
#       a registry lane id or a stage-<s> id, p99 > 0; value 3x p99 to the cent
#   S2  a PUT answered with another value is `error <lane> settings-write`, rc 1
#   S3  the `# >>> spend ceiling seed` block of bin/pipeline-health.sh with no
#       knob rows: 3x and min 7 days, the marker, a second drive makes 0 reads
#   S4  an operator row (any value, `off` included) is kept, never rewritten
#   S5  a failed GET: rc 1, no marker, one alert; the retry PUTs only the gap
#   S6  SPEND_CEILING_SEED=0 does nothing; --dry-run makes 0 PUTs
#   R1  round trip: the real spend-alerts baseline -> the real seeder -> the
#       settings cache -> the real agent-call refuses at the seeded value
#
# Drives the real libs, agent-call, jobs client and seeder against a fake curl
# worker; asserts on artifacts only.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/spend-ceiling.bh-5526-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 120 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- fixture -----------------------------------------------------------------
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/builds" "$T/bin/lib/jobs" "$T/logs" "$T/state" "$T/catalog"
for f in bin/jobs-client.sh bin/alert-line.sh bin/lib/rb/gates.sh bin/spend-alerts.sh; do
  scratch_install_closure "$f" "$T" >/dev/null || { echo "cannot install the closure of $f"; exit 1; }
done
SEEDER_OK=0
if [ -f "$DIR/bin/spend-ceiling-seed.sh" ]; then
  scratch_install_closure bin/spend-ceiling-seed.sh "$T" >/dev/null && SEEDER_OK=1
fi
[ "$SEEDER_OK" = 1 ] && ok || bad "bin/spend-ceiling-seed.sh is missing or its closure cannot be installed"
SEED="$T/bin/spend-ceiling-seed.sh"
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
# The worker.
#   llm-spend      -> $SPEND_USD; SPEND_FAKE=down is a transport failure
#   GET  settings  -> the row in $STORE (a {key:{value,actor}} map) or null;
#                     a key listed in $GETFAIL is a transport failure
#   PUT  settings  -> stores the body, answers the stored row; with
#                     $T/putwrong present it answers another value
# Every URL goes to $REQ_LOG, every PUT body to $PUT_LOG.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift ;; --data-binary) BODY="$2"; shift ;; esac
  shift
done
printf '%s %s\n' "$M" "$URL" >> "$REQ_LOG"
case "$M $URL" in
  "GET "*/api/metrics/llm-spend\?*)
    [ "${SPEND_FAKE:-}" = down ] && exit 7
    printf '{"usd":%s,"calls":3,"refused":0,"settled":0}\n200\n' "${SPEND_USD:-0}" ;;
  "GET "*/api/settings/*)
    k="${URL##*/api/settings/}"
    grep -qxF "$k" "$GETFAIL" 2>/dev/null && exit 7
    [ -s "$STORE" ] || echo '{}' > "$STORE"
    jq -c --arg k "$k" '{key:$k, setting:(if .[$k] then {key:$k, value:.[$k].value, actor:.[$k].actor} else null end)}' "$STORE"
    echo 200 ;;
  "PUT "*/api/settings)
    printf '%s\n' "$BODY" >> "$PUT_LOG"
    [ -s "$STORE" ] || echo '{}' > "$STORE"
    k=$(printf '%s' "$BODY" | jq -r .key); v=$(printf '%s' "$BODY" | jq -r .value); a=$(printf '%s' "$BODY" | jq -r .actor)
    jq -c --arg k "$k" --arg v "$v" --arg a "$a" '.[$k]={value:$v,actor:$a}' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
    [ -e "$(dirname "$STORE")/putwrong" ] && v="999.99"
    jq -nc --arg k "$k" --arg v "$v" --arg a "$a" '{setting:{key:$k,value:$v,actor:$a}}'
    echo 200 ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
settings() { jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/req.log"; : > "$T/put.log"
  : > "$T/logs/lane-gate.log"; rm -rf "$T/state/lane-gate" "$T/state/alert-line-sent"
  rm -f "$T/logs/cost.csv" "$T/flags/"* "$T/store.json" "$T/getfail" "$T/putwrong"; rm -rf "$T/builds" "$T/s5"; mkdir -p "$T/builds"
  settings '{}'
}
admit() { mkdir -p "$T/builds/$1"; echo "2026-10-08T00:00:00Z K-1" > "$T/builds/$1/ADMITTED"; }
ENVS=(REQ_LOG="$T/req.log" PUT_LOG="$T/put.log" STORE="$T/store.json" GETFAIL="$T/getfail"
      PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T"
      HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 LANE_REGISTRY="$T/lanes.json")
# call <lane> <stage> <out> [VAR=VAL ...] -> the rc of the REAL bin/agent-call.sh
call() {
  local ln="$1" st="$2" out="$3"; shift 3
  mkdir -p "$(dirname "$out")"
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID LLM_GATE_IN_TICKET LLM_USD_CAP_DAY
    export "${ENVS[@]}" ORDER_SINK="$T/order" \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=0 \
           AGENT_CALL_LANE="$ln" IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$st" testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
norder() { grep -c . "$T/order"; }
nspend() { grep -c "llm-spend?lane=$1\$" "$T/req.log"; }   # lane-only reads (no stage)
nalerts() { grep -c . "$T/logs/ALERTS.log"; }
CEIL() { printf '{"spend.ceiling.%s.day_usd":"%s"}' "$1" "$2"; }

# =============================================================================
# C1 — an admitted ticket runs execute and review over the ceiling
# =============================================================================
reset; settings "$(CEIL fly-pool 10)"; admit testproj-K-1
R1=$(call fly-pool execute "$T/builds/testproj-K-1/execute.txt" SPEND_USD=50)
R2=$(call fly-pool review "$T/builds/testproj-K-1/review.txt" SPEND_USD=50)
[ "$R1|$R2" = "0|0" ] && ok || bad "C1 admitted execute/review over the ceiling: rc=$R1|$R2, want 0|0 ($(head -1 "$T/builds/testproj-K-1/execute.txt" 2>/dev/null))"
[ "$(norder)" = 2 ] && ok || bad "C1 the vendor was called $(norder) times, want 2"
[ "$(nspend fly-pool)" = 0 ] && ok || bad "C1 the ceiling was read inside an admitted ticket: $(cat "$T/req.log")"

# =============================================================================
# C2 — never inside a started ticket; an ENDED ticket is a start
# =============================================================================
reset; settings "$(CEIL fly-pool 10)"; admit testproj-K-1
R=$(call fly-pool execute "$T/builds/testproj-K-1/execute.txt" SPEND_USD=1000)
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "C2 admitted at \$1000: rc=$R order=$(norder)"
R=$(call fly-pool review "$T/builds/testproj-K-1/review.txt" SPEND_FAKE=down)
[ "$R" = 0 ] && [ "$(norder)" = 2 ] && ok || bad "C2 admitted, spend read down: rc=$R order=$(norder)"
echo "PR_CREATED https://x/pull/1" > "$T/builds/testproj-K-1/RESULT"
R=$(call fly-pool replan "$T/builds/testproj-K-1/replan-run.txt" SPEND_USD=50)
[ "$R" = 74 ] && [ "$(norder)" = 2 ] && ok || bad "C2 an ended ticket over the ceiling: rc=$R order=$(norder), want 74 and no call"

# =============================================================================
# C3 — lead-review over its ceiling: refused before the call, logged, alerted once
# =============================================================================
reset; settings "$(CEIL lead-review 10)"
R=$(call lead-review review "$T/lane/out.txt" SPEND_USD=50)
[ "$R" = 74 ] && ok || bad "C3 lead-review over its ceiling: rc=$R, want 74"
[ "$(norder)" = 0 ] && ok || bad "C3 the vendor was called"
grep -q '^AGENT_CALL_REFUSED llm-gate spend-ceiling lane=lead-review spent=\$50 ceiling=\$10' "$T/lane/out.txt" 2>/dev/null && ok \
  || bad "C3 \$OUT: $(head -1 "$T/lane/out.txt" 2>/dev/null)"
NREF=$(grep -c ',refused,.*refused:spend-ceiling' "$T/logs/cost.csv" 2>/dev/null); NREF=${NREF:-0}
[ "$NREF" = 1 ] && ok || bad "C3 want one refused cost row noting spend-ceiling, got $NREF: $(tail -1 "$T/logs/cost.csv" 2>/dev/null)"
[ "$(nalerts)" = 1 ] && grep -q 'spent=\$50' "$T/logs/ALERTS.log" && grep -q 'ceiling=\$10' "$T/logs/ALERTS.log" && ok \
  || bad "C3 want one ALERTS line naming spent=\$50 and ceiling=\$10: $(cat "$T/logs/ALERTS.log")"
R=$(call lead-review review "$T/lane/out.txt" SPEND_USD=50)
[ "$R" = 74 ] && [ "$(nalerts)" = 1 ] && ok || bad "C3 second refusal the same day: rc=$R alerts=$(nalerts), want 74 and 1"
# The decision table.
dt() { # dt <label> <want called|refused> <settings-json> [VAR=VAL ...]
  local lbl="$1" want="$2" s="$3" rc; shift 3
  reset; settings "$s"
  rc=$(call lead-review review "$T/lane/out.txt" "$@")
  if [ "$want" = called ]; then
    [ "$rc" = 0 ] && [ "$(norder)" = 1 ] && ok || bad "C3 $lbl: rc=$rc order=$(norder), want the vendor called"
  else
    [ "$rc" = 74 ] && [ "$(norder)" = 0 ] && ok || bad "C3 $lbl: rc=$rc order=$(norder), want refused"
  fi
}
dt "spend 9.99" called "$(CEIL lead-review 10)" SPEND_USD=9.99
dt "spend 10 (the edge)" refused "$(CEIL lead-review 10)" SPEND_USD=10
dt "spend 0" called "$(CEIL lead-review 10)" SPEND_USD=0
for v in off 0 abc; do
  dt "row '$v'" called "$(CEIL lead-review "$v")" SPEND_USD=50
  [ "$(nspend lead-review)" = 0 ] && ok || bad "C3 row '$v' made a spend read: $(cat "$T/req.log")"
done
grep -q 'ceiling' "$T/logs/lane-gate.log" && ok || bad "C3 a junk row 'abc' wrote no lane-gate.log line"
dt "no row" called '{}' SPEND_USD=50
[ "$(nspend lead-review)" = 0 ] && ok || bad "C3 no row made a spend read"
reset; settings "$(CEIL lead-review 10)"; touch "$T/flags/spend-ceiling-off"
R=$(call lead-review review "$T/lane/out.txt" SPEND_USD=50)
[ "$R" = 0 ] && [ "$(norder)" = 1 ] && [ "$(nspend lead-review)" = 0 ] && ok \
  || bad "C3 the spend-ceiling-off switch: rc=$R order=$(norder) reads=$(nspend lead-review)"
dt "spend read down" called "$(CEIL lead-review 10)" SPEND_FAKE=down
[ "$(grep -c 'ceiling' "$T/logs/lane-gate.log")" = 1 ] && ok \
  || bad "C3 spend read down: want one lane-gate.log line naming the ceiling: $(cat "$T/logs/lane-gate.log")"

# =============================================================================
# C4 — the launch gate block in bin/lib/rb/gates.sh
# =============================================================================
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$DIR/bin/lib/rb/gates.sh" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "C4 no '# >>> budget launch gate' block"
launch() { # launch <build-subdir> [VAR=VAL ...] -> rc
  local b="$T/s5/$1"; shift
  mkdir -p "$b"
  ( unset LLM_USD_CAP_DAY; export "${ENVS[@]}" BUILD="$b" "$@"
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
reset; settings "$(CEIL fly-pool 10)"
R=$(launch a SPEND_USD=50)
[ "$R" = 3 ] && ok || bad "C4 fresh build over the fly-pool ceiling: rc=$R, want 3"
grep -q '^BUILD_DEFERRED spend-ceiling lane=fly-pool spent=\$50 ceiling=\$10' "$T/s5/a/RESULT" 2>/dev/null && ok \
  || bad "C4 RESULT: $(cat "$T/s5/a/RESULT" 2>/dev/null)"
[ ! -e "$T/s5/a/ADMITTED" ] && [ ! -e "$T/s5/a/reached" ] && ok || bad "C4 the refused launch was admitted or went past the gate"
grep -q 'spend-ceiling' "$T/s5/a/pipeline.log" 2>/dev/null && ok || bad "C4 no pipeline.log line"
[ "$(nalerts)" = 1 ] && grep -q 'spend-ceiling' "$T/logs/ALERTS.log" && ! grep -q 'refused at ticket start' "$T/logs/ALERTS.log" && ok \
  || bad "C4 want exactly the one lane alert, no per-project launch alert: $(cat "$T/logs/ALERTS.log")"
[ ! -e "$T/flags/alerted-llm-cap-launch-testproj-$(date -u +%Y%m%d)" ] && ok || bad "C4 the per-project llm-cap-launch alert was claimed"
C4_RESULT=$(cat "$T/s5/a/RESULT" 2>/dev/null)
awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf.sh"
R=$(bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf.sh" "$C4_RESULT")
[ "$R" = 0 ] && ok || bad "C4 pool_lane_failure counts the spend-ceiling deferral against the ticket"
# A resume of an admitted dir is the same ticket in progress: no read.
: > "$T/req.log"; mkdir -p "$T/s5/c"; echo "2026-10-08T00:00:00Z K-5" > "$T/s5/c/ADMITTED"
R=$(launch c SPEND_USD=50 RESUME_BUILD="$T/s5/c")
[ "$R" = 0 ] && [ -e "$T/s5/c/reached" ] && [ "$(nspend fly-pool)" = 0 ] && ok \
  || bad "C4 resume of an admitted dir: rc=$R reads=$(nspend fly-pool)"
R=$(launch e SPEND_USD=5)
[ "$R" = 0 ] && grep -q ' K-5$' "$T/s5/e/ADMITTED" 2>/dev/null && ok || bad "C4 under the ceiling: rc=$R, no ADMITTED"

# =============================================================================
# C5 — another lane inside an admitted dir checks its own ceiling
# =============================================================================
reset; settings "$(CEIL postmerge-qa 10)"; admit testproj-K-1
R=$(call postmerge-qa qa-prod "$T/builds/testproj-K-1/qa-prod-run.txt" SPEND_USD=50)
[ "$R" = 74 ] && [ "$(norder)" = 0 ] && ok || bad "C5 postmerge-qa in an admitted dir over its ceiling: rc=$R order=$(norder), want 74"

# =============================================================================
# S1-S6 — the seeder and its pipeline-health block
# =============================================================================
DAYC=$(date -u +%Y%m%d)
cat > "$T/catalog/lanes.json" <<'EOF'
{"version":1,"lanes":[{"id":"fly-pool"},{"id":"lead-review"},{"id":"alert-triage"},{"id":"quiet"}]}
EOF
printf 'lane\tfly-pool\t100.00\t14\nlane\tlead-review\t4.10\t7\nlane\talert-triage\t9.00\t6\nlane\texecute\t3.00\t14\nlane\tstage-review\t2.00\t9\nlane\tquiet\t0.00\t10\nproject\tcromford\t900.00\t14\n' > "$T/base.tsv"
seed() { # seed [args...] -> stdout of the real seeder; rc in $T/seed.rc
  ( export "${ENVS[@]}"; bash "$SEED" --baseline "$T/base.tsv" --mult 3 --min-days 7 --registry "$T/catalog/lanes.json" "$@" 2>"$T/seed.err" )
  echo $? > "$T/seed.rc"
}
puts() { jq -r '"\(.key)=\(.value)=\(.actor)"' "$T/put.log" 2>/dev/null | LC_ALL=C sort; }

# S1
reset; OUT=$(seed)
[ "$(cat "$T/seed.rc")" = 0 ] && ok || bad "S1 seeder rc=$(cat "$T/seed.rc") ($(cat "$T/seed.err" 2>/dev/null))"
WANT=$(printf '%s\n' "spend.ceiling.fly-pool.day_usd=300.00=spend-ceiling-seed" \
  "spend.ceiling.lead-review.day_usd=12.30=spend-ceiling-seed" "spend.ceiling.stage-review.day_usd=6.00=spend-ceiling-seed" | LC_ALL=C sort)
[ "$(puts)" = "$WANT" ] && ok || bad "S1 PUTs: [$(puts)] want [$WANT]"
grep -qx 'seeded fly-pool 300.00 p99=100.00 days=14' <<<"$OUT" && ok || bad "S1 stdout: [$OUT]"
grep -q 'alert-triage\|execute\|quiet\|cromford' "$T/req.log" && bad "S1 a non-candidate was even read: $(cat "$T/req.log")" || ok

# S2 — status evidence: the PUT answered another value
reset; touch "$T/putwrong"; OUT=$(seed)
[ "$(cat "$T/seed.rc")" = 1 ] && ok || bad "S2 seeder rc=$(cat "$T/seed.rc"), want 1"
grep -qx 'error fly-pool settings-write' <<<"$OUT" && ok || bad "S2 stdout: [$OUT]"
grep -q '^seeded' <<<"$OUT" && bad "S2 printed seeded for a write that did not land: [$OUT]" || ok

# S4 — an operator value wins
reset; echo '{"spend.ceiling.fly-pool.day_usd":{"value":"500","actor":"operator"},"spend.ceiling.lead-review.day_usd":{"value":"off","actor":"operator"}}' > "$T/store.json"
OUT=$(seed)
[ "$(cat "$T/seed.rc")" = 0 ] && ok || bad "S4 seeder rc=$(cat "$T/seed.rc")"
grep -q 'fly-pool\|lead-review' "$T/put.log" && bad "S4 an operator row was rewritten: $(cat "$T/put.log")" || ok
grep -qx 'kept fly-pool 500 operator' <<<"$OUT" && grep -q '^kept lead-review off ' <<<"$OUT" && ok \
  || bad "S4 stdout: [$OUT]"
[ "$(puts)" = "spend.ceiling.stage-review.day_usd=6.00=spend-ceiling-seed" ] && ok || bad "S4 PUTs: [$(puts)]"

# S6b — dry run
reset; OUT=$(seed --dry-run)
[ "$(cat "$T/seed.rc")" = 0 ] && [ ! -s "$T/put.log" ] && ok || bad "S6 --dry-run: rc=$(cat "$T/seed.rc") puts=[$(cat "$T/put.log")]"
grep -q 'fly-pool 300.00' <<<"$OUT" && ok || bad "S6 --dry-run printed no row for fly-pool: [$OUT]"
grep -q '^seeded' <<<"$OUT" && bad "S6 --dry-run claimed a write: [$OUT]" || ok

# Usage
( export "${ENVS[@]}"; bash "$SEED" --mult 3 >/dev/null 2>&1 ); RC=$?
[ "$RC" = 2 ] && ok || bad "seeder with no --baseline: rc=$RC, want 2"
( export "${ENVS[@]}"; echo '{}' > "$T/empty-reg.json"; bash "$SEED" --baseline "$T/base.tsv" --mult 3 --min-days 7 --registry "$T/empty-reg.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 1 ] && ok || bad "seeder with an empty registry: rc=$RC, want 1"

# --- the pipeline-health block -----------------------------------------------
H="$T"
awk '/^# >>> spend ceiling seed/{f=1;next} /^# <<< spend ceiling seed/{exit} f' "$DIR/bin/pipeline-health.sh" > "$H/blk.sh"
[ -s "$H/blk.sh" ] && ok || bad "no '# >>> spend ceiling seed' block in bin/pipeline-health.sh"
awk '/^sa_knob\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$H/sa-knob.sh"
cat > "$H/bin/ph-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; NOW=$(date -u +%s)
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
alert() { printf '%s\t%s\n' "$2" "$3" >> "$H/alerts.rec"; }
lane_knob() { [ "$1" = pipeline-health ] || return 0; awk -F= -v k="$2" '$1==k{print $2}' "$H/knobs" 2>/dev/null; }
. "$H/sa-knob.sh"
. "$H/blk.sh"
SH
chmod +x "$H/bin/ph-driver.sh"
drive() { ( unset SPEND_CEILING_SEED SPEND_CEILING_P99_MULT SPEND_CEILING_MIN_DAYS; export "${ENVS[@]}" LANE_REGISTRY= "$@"; bash "$H/bin/ph-driver.sh" >/dev/null 2>&1 ); }
nsettings() { grep -c '/api/settings' "$T/req.log"; }
MARK="$H/state/spend-alerts/ceiling-seeded-$DAYC"
blk_reset() { reset; : > "$H/alerts.rec"; : > "$H/knobs"; scratch_rm "$T/state/spend-alerts"; mkdir -p "$H/state/spend-alerts"; cp "$T/base.tsv" "$H/state/spend-alerts/baseline-$DAYC.tsv"; }

# S3 — defaults
blk_reset; touch "$H/state/spend-alerts/ceiling-seeded-20200101"; drive
[ "$(puts)" = "$WANT" ] && ok || bad "S3 no knob rows: PUTs [$(puts)] want 3x and min 7 days [$WANT]"
[ -f "$MARK" ] && ok || bad "S3 the marker was not written"
[ ! -e "$H/state/spend-alerts/ceiling-seeded-20200101" ] && ok || bad "S3 an older marker was kept"
grep -q 'spend ceiling seed: seeded fly-pool 300.00' "$H/logs/pipeline-health.log" 2>/dev/null && ok \
  || bad "S3 no pipeline-health.log line: $(cat "$H/logs/pipeline-health.log" 2>/dev/null)"
: > "$T/req.log"; drive
[ "$(nsettings)" = 0 ] && ok || bad "S3 a second drive the same day made $(nsettings) settings requests"
# No baseline today: nothing runs.
blk_reset; rm -f "$H/state/spend-alerts/baseline-$DAYC.tsv"; drive
[ "$(nsettings)" = 0 ] && [ ! -f "$MARK" ] && ok || bad "S3 no baseline today: requests=$(nsettings)"

# S5 — a partial failure retries and alerts once
blk_reset; echo spend.ceiling.lead-review.day_usd > "$T/getfail"; drive
[ ! -f "$MARK" ] && ok || bad "S5 the marker was written after a failure"
[ "$(puts)" = "$(printf '%s\n' "spend.ceiling.fly-pool.day_usd=300.00=spend-ceiling-seed" "spend.ceiling.stage-review.day_usd=6.00=spend-ceiling-seed")" ] && ok \
  || bad "S5 the other keys were not seeded: [$(puts)]"
[ "$(grep -c '^spendceilingseed:fleet	' "$H/alerts.rec")" = 1 ] && ok || bad "S5 alerts: $(cat "$H/alerts.rec")"
grep -q 'error lead-review settings-read' "$H/alerts.rec" && ok || bad "S5 the alert does not name the error: $(cat "$H/alerts.rec")"
rm -f "$T/getfail"; : > "$T/put.log"; drive
[ "$(puts)" = "spend.ceiling.lead-review.day_usd=12.30=spend-ceiling-seed" ] && ok || bad "S5 retry PUTs: [$(puts)]"
[ -f "$MARK" ] && ok || bad "S5 the retry did not write the marker"

# S6 — switched off
blk_reset; echo SPEND_CEILING_SEED=0 > "$H/knobs"; drive
[ "$(nsettings)" = 0 ] && [ ! -f "$MARK" ] && ok || bad "S6 SPEND_CEILING_SEED=0: requests=$(nsettings) marker=$([ -f "$MARK" ] && echo yes)"
# A knob row changes the multiplier; a min-days row under 7 is not honoured below 7.
blk_reset; printf 'SPEND_CEILING_P99_MULT=2\nSPEND_CEILING_MIN_DAYS=3\n' > "$H/knobs"; drive
grep -q 'spend.ceiling.fly-pool.day_usd=200.00' <<<"$(puts)" && ! grep -q alert-triage "$T/put.log" && ok \
  || bad "S6 knob rows: PUTs [$(puts)] want fly-pool 200.00 and no 6-day lane"

# =============================================================================
# R1 — round trip: baseline -> seeder -> settings cache -> agent-call
# =============================================================================
reset
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
{
  echo "$HDR"
  i=0
  for c in 20 12 11 10 9 8 7 6; do
    i=$((i+1))
    printf '%sT10:00:00Z,box,testproj,execute,claude,m,0,1,0,0,0,0,%s,api,,,,,,,,,,,fly-pool,\n' "$(date -u -d "2026-10-08 -$i days" +%F)" "$c"
  done
} > "$T/r1.csv"
"$T/bin/spend-alerts.sh" baseline --rows "$T/r1.csv" --until 2026-10-08 --days 14 --min-days 7 > "$T/r1.tsv" 2>/dev/null
grep -qxF "$(printf 'lane\tfly-pool\t20.00\t8')" "$T/r1.tsv" && ok || bad "R1 baseline: $(cat "$T/r1.tsv")"
( export "${ENVS[@]}"; bash "$SEED" --baseline "$T/r1.tsv" --mult 3 --min-days 7 --registry "$T/catalog/lanes.json" >/dev/null 2>&1 )
V=$(jq -r 'select(.key=="spend.ceiling.fly-pool.day_usd") | .value' "$T/put.log" 2>/dev/null)
[ "$V" = 60.00 ] && ok || bad "R1 seeded value: '$V', want 60.00"
settings "$(jq -sc 'map({(.key): .value}) | add // {}' "$T/put.log")"
R=$(call fly-pool execute "$T/lane/r1.txt" SPEND_USD=60)
[ "$R" = 74 ] && ok || bad "R1 at the seeded value: rc=$R, want 74"
R=$(call fly-pool execute "$T/lane/r1.txt" SPEND_USD=59.99)
[ "$R" = 0 ] && ok || bad "R1 under the seeded value: rc=$R, want 0"

echo "spend-ceiling.bh-5526: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
