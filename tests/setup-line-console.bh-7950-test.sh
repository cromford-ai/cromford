#!/bin/bash
# tests/setup-line-console.bh-7950-test.sh — the setup line screen on
# /projects/:project/setup/:runId and its retry/cancel routes (BH-7950,
# BH-7934.3).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/setup-line.bh-7934.test.js and
# worker/jobs/test/onboarding-actions.bh-7934.test.js. This file is the part the
# impact lane and the orphan ratchet can SEE: it names the new sources by path,
# drives the screen's pure half, and runs both node suites.
#
#   1. screens/SetupLine.js, DRIVEN: nextPollMs, formatDuration, setupView.
#   2. the route row in app.js, the two coord write rows, and no native dialog.
#   3. the two node suites, run for real when their dependencies are installed.
# Run from anywhere: tests/setup-line-console.bh-7950-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/SetupLine.js"
APP="$DIR/console-ui/src/app.js"
WRITES="$DIR/console-ui/functions/_lib/coord-writes.d/7934-onboarding.js"
ROUTE="$DIR/worker/jobs/src/routes/onboarding-actions.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-7934-onboarding-actions.txt"

for f in "$SCREEN" "$APP" "$WRITES" "$ROUTE" "$FRAG"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "setup-line-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the screen's pure half, driven ---------------------------------------
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  OUT=$(node --input-type=module -e "
globalThis.window = { location: { pathname: '/', search: '' }, addEventListener() {}, dispatchEvent() {} };
const { nextPollMs, formatDuration, setupView } = await import('$SCREEN');
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const S = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];
const fx = (state, states) => ({ run: { project: 'demo', state }, steps: states.map((st, i) => ({ station: S[i], ord: i + 1, state: st, retries: 0,
  started_at: st === 'queued' ? null : '2026-10-22T10:00:00Z', finished_at: st === 'done' ? '2026-10-22T10:00:42Z' : null,
  error_code: st === 'failed' ? 'station_failed' : null, log_excerpt: null })) });
eq('poll-running', nextPollMs('running'), 5000);
eq('poll-failed', nextPollMs('failed'), 0);
eq('dur-s', formatDuration('2026-10-22T10:00:00Z', '2026-10-22T10:00:42Z', 0), '42s');
eq('dur-m', formatDuration('2026-10-22T10:00:00Z', '2026-10-22T10:03:05Z', 0), '3m 05s');
const f = setupView(fx('failed', ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped']), 0);
eq('eyebrow-failed', f.eyebrow, 'STATION 3 OF 7');
eq('fix-no-link', f.stations[2].fix.href, null);
eq('open-failed', [f.openEnabled, f.canCancel], [false, true]);
const d = setupView(fx('done', Array(7).fill('done')), 0);
eq('open-done', [d.openEnabled, d.openHref, d.canCancel], [true, '/p/demo', false]);
" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok ;;
      no\ *) bad "screen: ${line#no }" ;;
      *) [ -n "$line" ] && bad "screen: unexpected output: $line" ;;
    esac
  done <<< "$OUT"
else
  echo "setup-line-console: screen drive SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

# --- 2: the wiring ----------------------------------------------------------
grep -q "\['/projects/:project/setup/:runId', SetupLineScreen\]" "$APP" && ok || bad "app.js must route /projects/:project/setup/:runId to SetupLineScreen"
grep -q "isActionPath('retry')" "$WRITES" && grep -q "isActionPath('cancel')" "$WRITES" && ok || bad "7934-onboarding.js must hold the retry and cancel rows"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the setup line screen"
else
  ok
fi

# --- 3: the node suites, driven ----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "setup-line-console: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/setup-line.bh-7934.test.js 2>&1); then ok
  else bad "console-ui/tests/setup-line.bh-7934.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "setup-line-console: worker node suite SKIPPED — catalog/lanes.json is not rendered (the worker CI job runs it)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/onboarding-actions.bh-7934.test.js 2>&1); then ok
else bad "worker/jobs/test/onboarding-actions.bh-7934.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "setup-line-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
