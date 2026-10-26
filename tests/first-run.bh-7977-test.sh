#!/bin/bash
# tests/first-run.bh-7977-test.sh — the fleet first-run screen (BH-7977,
# BH-7939.3): GET /api/fleet/first-run and the console screen `/` shows in
# place of the Fleet list while a required account is missing.
#
# The route is proved by node --test in worker/jobs (fleet-first-run.bh-7939
# and fleet-first-run-explain.bh-7977), the screen by
# console-ui/tests/first-run.bh-7939.test.js. This file is the part the impact
# lane and the orphan ratchet can SEE: it names every new source by path,
# drives the pure helpers for real, and runs the node suites when their
# dependencies are installed.
#
#   1. console lib/first-run.js, DRIVEN: only `true` is true, `complete` is
#      recomputed, showFirstRun needs the gate AND a missing account.
#   2. the worker and console shapes have the same field names.
#   3. the wiring: `/` imports the loader and FirstRun; no native dialog.
#   4. the node suites, run for real when node_modules is installed. Their
#      fetches are same-origin /api/ only and node:sqlite: 0 vendor calls.
# Run from anywhere: tests/first-run.bh-7977-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/first-run.js"
SCREEN="$DIR/console-ui/src/screens/FirstRun.js"
FLEET="$DIR/console-ui/src/screens/Fleet.js"
ROUTE="$DIR/worker/jobs/src/routes/fleet-first-run.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-7939-fleet-first-run.txt"
GATE_SQL="$DIR/worker/jobs/schema.d/202610250546-bh-7977-first-run-gate.sql"
NODE_UI="$DIR/console-ui/tests/first-run.bh-7939.test.js"
NODE_W="$DIR/worker/jobs/test/fleet-first-run.bh-7939.test.js"
NODE_X="$DIR/worker/jobs/test/fleet-first-run-explain.bh-7977.test.js"

for f in "$LIB" "$SCREEN" "$FLEET" "$ROUTE" "$FRAG" "$GATE_SQL" "$NODE_UI" "$NODE_W" "$NODE_X"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
grep -qx 'GET /api/fleet/first-run' "$FRAG" && ok || bad "the route-table fragment must list GET /api/fleet/first-run"
grep -q "INSERT OR IGNORE INTO settings" "$GATE_SQL" && ok || bad "the gate fragment must seed with INSERT OR IGNORE"

command -v node >/dev/null 2>&1 || { echo "first-run: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1 + 2: the helpers, driven ------------------------------------------------
OUT=$(node --input-type=module -e "
import { firstRunFrom, showFirstRun, FIRST_RUN_CARDS, FIRST_RUN_PATH } from '$LIB';
import { firstRunFrom as workerFrom } from '$ROUTE';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const all3 = { anthropic: true, github_app: true, telegram: true };
eq('complete',          firstRunFrom({ ...all3, more_ai: false, gate: true }).complete, true);
eq('more-ai-not-req',   firstRunFrom({ ...all3, more_ai: false }).complete, true);
eq('one-missing',       firstRunFrom({ ...all3, telegram: false, complete: true }).complete, false);
eq('truthy-not-true',   firstRunFrom({ anthropic: 1, github_app: 'true', telegram: true }).complete, false);
eq('null-body',         firstRunFrom(null), { anthropic: false, github_app: false, telegram: false, more_ai: false, gate: false, complete: false });
eq('show',              showFirstRun(firstRunFrom({ anthropic: true, gate: true })), true);
eq('show-complete',     showFirstRun(firstRunFrom({ ...all3, gate: true })), false);
eq('show-gate-off',     showFirstRun(firstRunFrom({ anthropic: true, gate: false })), false);
eq('show-gate-absent',  showFirstRun(firstRunFrom({ anthropic: true })), false);
eq('show-gate-string',  showFirstRun(firstRunFrom({ anthropic: true, gate: 'yes' })), false);
eq('show-null',         showFirstRun(null), false);
eq('cards',             FIRST_RUN_CARDS.map((c) => c.id), ['anthropic', 'github_app', 'telegram', 'more_ai']);
eq('path',              FIRST_RUN_PATH, '/api/coord/fleet/first-run');
// The worker's answer and the console's shape carry the same field names.
const w = workerFrom({ anthropic: 1, github_app: 1, telegram: 0, more_ai: 1, gate: 1 });
eq('same-fields',       Object.keys(w).sort(), Object.keys(firstRunFrom(w)).sort());
eq('round-trip',        firstRunFrom(w), w);
eq('worker-null-row',   workerFrom(null).gate, false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "first-run helpers: ${line#no }" ;;
    *) [ -n "$line" ] && bad "first-run helpers: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the wiring -------------------------------------------------------------
grep -q "from '../lib/first-run.js'" "$FLEET" && ok || bad "Fleet.js must import ../lib/first-run.js"
grep -q "from './FirstRun.js'" "$FLEET" && ok || bad "Fleet.js must import ./FirstRun.js"
grep -q "from './AiAccountSheet.js'" "$SCREEN" && ok || bad "FirstRun.js must reuse the AI account add sheet"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog on the first-run screen"
else
  ok
fi

# --- 4: the node suites, driven ------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "first-run: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/first-run.bh-7939.test.js 2>&1); then ok
  else bad "console-ui/tests/first-run.bh-7939.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi
if [ ! -f "$DIR/catalog/lanes.json" ] || [ ! -f "$DIR/catalog/llm-sites.json" ] || [ ! -f "$DIR/catalog/context-budgets.json" ] \
  || [ ! -d "$DIR/worker/jobs/node_modules" ]; then
  echo "first-run: worker node suites SKIPPED — a rendered catalog or worker/jobs/node_modules is absent (the worker-jobs CI job runs them)"
else
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/fleet-first-run.bh-7939.test.js test/fleet-first-run-explain.bh-7977.test.js 2>&1); then ok
  else bad "the worker first-run suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "first-run: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
