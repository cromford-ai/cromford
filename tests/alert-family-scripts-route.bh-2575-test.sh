#!/bin/bash
# tests/alert-family-scripts-route.bh-2575-test.sh — the /api/alert-family-scripts
# worker route (BH-2575, BH-2544.3).
#
# The route's behaviour is proved by node --test in
# worker/jobs/test/alert-family-scripts.bh-2544.test.js, through worker.fetch
# against node:sqlite. What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the new source by path, checks it is wired
# into ROUTES (and not OPEN_ROUTES), and runs that node suite for real.
# Run from anywhere: tests/alert-family-scripts-route.bh-2575-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SRC="$DIR/worker/jobs/src/routes/alert-family-scripts.js"
INDEX="$DIR/worker/jobs/src/index.js"
SUITE="$DIR/worker/jobs/test/alert-family-scripts.bh-2544.test.js"

for f in "$SRC" "$INDEX" "$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-alert-family-scripts.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "alert-family-scripts has no route-table.d fragment (BH-4607: the fragment IS the registration)"

if ! command -v node >/dev/null 2>&1; then
  echo "alert-family-scripts-route: node suite SKIPPED — node is not installed on this box"
else
  if [ ! -f "$DIR/catalog/lanes.json" ]; then
    HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
      || bad "could not generate catalog/lanes.json the worker imports"
  fi
  # Both verbs match in ROUTES (the bearer table) and in OPEN_ROUTES not at all.
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
for (const [v, p] of [['GET', '/api/alert-family-scripts'], ['PUT', '/api/alert-family-scripts/disk-full']]) {
  console.log(v, matchRoute(ROUTES, v, p) ? 'bearer' : 'none', matchRoute(OPEN_ROUTES, v, p) ? 'open' : 'closed');
}" 2>&1)
  [ "$ROUTED" = $'GET bearer closed\nPUT bearer closed' ] && ok || bad "route wiring: $ROUTED"
  if OUT=$(cd "$DIR/worker/jobs" && node --test "$SUITE" 2>&1); then ok
  else bad "node suite failed:"; printf '%s\n' "$OUT" | grep -E '^not ok|error' | head -20; fi
fi

echo "alert-family-scripts-route: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
