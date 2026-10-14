#!/bin/bash
# tests/pr-state-queue-rows.bh-5667-test.sh — BH-5667 (BH-5008 child 1): a
# merge-queue stage row (pr_state_events state='queue') is not a conductor
# tick. Drives the real bin/state-flip-evidence.sh pr-state-rows behind the
# fake curl of tests/lib/qrf-fixture.sh:
#   Q1  the filtered read is empty, only the unfiltered one holds a queue row
#       → tick FAIL "no pr_state_events row since"
#   Q2  a conductor row after --since on the filtered read → tick PASS
#   Q3  the tick asked with not_state=queue
# Also names the BH-5667 sources for bin/test-impact.sh and runs their node
# suites when node (and, for the console, its dependencies) is installed.
# Run from anywhere: tests/pr-state-queue-rows.bh-5667-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$DIR/bin/lib/sfe/pr-state-rows.sh"; do
  [ -f "$f" ] || { bad "$f missing"; continue; }
  bash -n "$f" || bad "$f does not parse"
done
for f in "$DIR/worker/jobs/src/lib/merge-queue-intake.js" "$DIR/worker/jobs/src/lib/merge-queue-stage.js" \
         "$DIR/worker/jobs/src/lib/merge-queue-intake-medians.js" "$DIR/worker/jobs/src/lib/merge-queue-intake-stages.js" \
         "$DIR/worker/jobs/src/lib/merge-queue-live-progress.js" "$DIR/worker/jobs/src/lib/merge-queue-live-stages.js" \
         "$DIR/worker/jobs/src/routes/merge-queue-live.js" "$DIR/worker/jobs/src/routes/merge-queue-reconcile.js" \
         "$DIR/worker/jobs/src/routes/webhooks.js" "$DIR/worker/jobs/src/routes/pr-state.js" \
         "$DIR/worker/jobs/src/lib/daily-digest/state-sections.js" \
         "$DIR/console-ui/src/ui/merge-queue-live-data.js" "$DIR/console-ui/src/ui/merge-queue-live.js" \
         "$DIR/console-ui/src/ui/merge-queue-waiting.js" "$DIR/console-ui/src/ui/pr-stage-track.js"; do
  [ -f "$f" ] && ok || bad "$f missing"
done
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

SINCE=2026-10-07T00:00:00Z
case_init() { qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }; OUT="$T/$1/out"; ERR="$T/$1/err"
  mkdir -p "$HARNESS/state/merge-conductor" "$HARNESS/logs" "$HARNESS/flags"; }
run() { bash "$HARNESS/bin/state-flip-evidence.sh" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
green() {
  qrf_fixture_route GET /api/flags/pr-state-rows 200 '{"flag":{"name":"pr-state-rows","active":1,"updated_at":"2026-10-07T00:00:00Z"}}'
}
QROW='{"rows":[{"id":9,"repo":"Example-Org/example-repo","number":101,"state":"queue","reason":"checking","at":"2026-10-07T00:05:00Z"}]}'
CROW='{"rows":[{"id":7,"repo":"Example-Org/example-repo","number":101,"state":"open","at":"2026-10-07T00:04:00Z"}]}'

# --- Q1: only a queue row is newer than the flip → tick FAIL ---
case_init q1; green
qrf_fixture_route GET '/api/pr-state-events?limit=1' 200 "$QROW"
qrf_fixture_route GET '/api/pr-state-events?limit=1&not_state=queue' 200 '{"rows":[]}'
run pr-state-rows --since "$SINCE"
check "Q1 rc 1" "[ $RC = 1 ]"
check "Q1 tick FAIL: no row since the flip" "grep -q '^\[FAIL\] tick: no pr_state_events row since' '$OUT'"
check "Q1 never a tick PASS" "! grep -q '^\[PASS\] newest pr_state_events row' '$OUT'"

# --- Q2: a conductor row after the flip → tick PASS ---
case_init q2; green
qrf_fixture_route GET '/api/pr-state-events?limit=1' 200 "$QROW"
qrf_fixture_route GET '/api/pr-state-events?limit=1&not_state=queue' 200 "$CROW"
run pr-state-rows --since "$SINCE"
check "Q2 tick PASS at the conductor row" "grep -q 'newest pr_state_events row at 2026-10-07T00:04:00Z, at or after the flip' '$OUT'"
check "Q2 no tick FAIL" "! grep -q '^\[FAIL\] tick' '$OUT'"

# --- Q3: the request log shows the filtered read, and only that one ---
check "Q3 tick asked with not_state=queue" "grep -qx 'GET /api/pr-state-events?limit=1&not_state=queue' '$QRF_FX/req.log'"
check "Q3 no unfiltered tick read" "! grep -qx 'GET /api/pr-state-events?limit=1' '$QRF_FX/req.log'"

# --- the node suites, when they can run ---
if ! command -v node >/dev/null 2>&1; then
  echo "pr-state-queue-rows: node suites SKIPPED — node is not installed on this box"
else
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/merge-queue-intake.bh-5667.test.js 2>&1); then ok
  else bad "worker/jobs/test/merge-queue-intake.bh-5667.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
  if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    echo "pr-state-queue-rows: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
  elif NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-queue-live-data.bh-5667.test.js 2>&1); then ok
  else bad "console-ui/tests/merge-queue-live-data.bh-5667.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "pr-state-queue-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
