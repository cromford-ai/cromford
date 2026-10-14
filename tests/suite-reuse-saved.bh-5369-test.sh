#!/bin/bash
# tests/suite-reuse-saved.bh-5369-test.sh — the suite ledger's saved minutes in
# Mission Control (BH-5369, BH-5354.3): two bearer-only worker reads and the
# SUITE REUSE section of /ci.
#
# The behaviour is proved by node --test in
# worker/jobs/test/suite-reuse-saved.bh-5354.test.js and
# console-ui/tests/suite-reuse.bh-5354.test.js. This file is the part the
# impact lane and the orphan ratchet can SEE (the ci-health-console.bh-2634
# pattern): it names the new sources by path and drives them.
#
#   1. lib/suite-reuse.js, DRIVEN: the tiles count class ci only, builder
#      minutes stay apart, absent rows are null, a non-GitHub url is dropped.
#   2. the route file, DRIVEN: the url rule links only a ci run key.
#   3. the screen uses the shared SortableTable and no native dialog.
#   4. the worker node suite, and the console node suite when the console-ui
#      dependencies are installed.
# Run from anywhere: tests/suite-reuse-saved.bh-5369-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/suite-reuse.js"
SCREEN="$DIR/console-ui/src/screens/CiHealth.js"
ROUTE="$DIR/worker/jobs/src/routes/suite-reuse-saved.js"
INDEX="$DIR/worker/jobs/src/index.js"

for f in "$LIB" "$SCREEN" "$ROUTE" "$INDEX"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "suite-reuse-saved: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1 + 2: the lib and the url rule, driven ---------------------------------
OUT=$(node --input-type=module -e "
import { savedRows, savedTiles, runRows } from '$LIB';
import { runUrl, reusedSuites } from '$ROUTE';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const now = Date.parse('2026-10-08T12:00:00Z');
const rows = savedRows({ rows: [
  { day: '2026-10-08', repo: 'r', class: 'ci', saved_s: 120 },
  { day: '2026-10-08', repo: 'r', class: 'builder', saved_s: 600 },
  { day: '2026-10-01', repo: 'r', class: 'ci', saved_s: 6000 } ] });
eq('tiles-ci-only', savedTiles(rows, now), { todayMin: 2, weekMin: 2, builderWeekMin: 10 });
eq('absent-null',   savedRows({}), null);
eq('url-dropped',   runRows({ rows: [{ url: 'https://evil.example/' }] }).rows[0].url, null);
const R = 'example-org/cromford';
eq('ci-link',       runUrl({ class: 'ci', repo: R, run_key: '123-1-0' }), 'https://github.com/' + R + '/actions/runs/123/attempts/1');
eq('builder-null',  runUrl({ class: 'builder', repo: R, run_key: '123-1-0' }), null);
eq('bad-repo-null', runUrl({ class: 'ci', repo: '../evil', run_key: '123-1-0' }), null);
eq('gate-key-null', runUrl({ class: 'ci', repo: R, run_key: 'example-BH-1-gate-1' }), null);
eq('suites-none',   reusedSuites({}), null);
eq('suites-bad',    reusedSuites({ reused_suites: '{x' }), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "driven: ${line#no }" ;;
    *) [ -n "$line" ] && bad "driven: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the screen's shape ----------------------------------------------------
grep -q "from '../lib/suite-reuse.js'" "$SCREEN" && ok || bad "CiHealth.js must render SUITE REUSE from lib/suite-reuse.js"
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-suite-reuse-saved.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "suite-reuse-saved has no route-table.d fragment (BH-4607: the fragment IS the registration)"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the SUITE REUSE section"
else
  ok
fi

# --- 4: the node suites, driven ------------------------------------------------
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
if node -e "require('node:sqlite')" > /dev/null 2>&1; then
  if WOUT=$(cd "$DIR/worker/jobs" && node --test test/suite-reuse-saved.bh-5354.test.js test/route-table.test.js 2>&1); then ok
  else bad "worker/jobs/test/suite-reuse-saved.bh-5354.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "suite-reuse-saved: worker node suite SKIPPED — node:sqlite is not available"
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "suite-reuse-saved: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/suite-reuse.bh-5354.test.js 2>&1); then ok
  else bad "console-ui/tests/suite-reuse.bh-5354.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "suite-reuse-saved: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
