#!/bin/bash
# tests/review-counts.bh-9154-test.sh — the daily review counter (BH-9154,
# Fix 5 of BH-9066): the worker route family, its retention rule, its schema
# fragment and the REVIEW COUNTS panel on the console's Lead reviews screen.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by two node suites,
# worker/jobs/test/review-counts.bh-9154.test.js (the real worker.fetch on
# node:sqlite) and console-ui/tests/review-counts.bh-9154.test.js (the real
# LeadReviewsScreen in a fake DOM). This file names every new source by path,
# so the impact lane and the orphan ratchet can see them, drives the pure
# half of the route with node, and runs both node suites when their
# dependencies are installed.
#
#   1. every new source exists, and the panel is mounted on the Lead reviews screen
#   2. kindMap and shapeDays, DRIVEN: a bad kind-map row falls back whole, an
#      unmapped kind is null (never 0), reviews per merged PR is null with no merge
#   3. the two node suites, run for real when node_modules is installed
# Run from anywhere: tests/review-counts.bh-9154-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT_DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$ROOT_DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$ROOT_DIR/worker/jobs/src/routes/review-counts.js"
RULE="$ROOT_DIR/worker/jobs/src/routes/retention.d/bh-9154-review-counts.js"
MOVER="$ROOT_DIR/worker/jobs/src/lib/archive-review-counts.js"
SCHEMA="$ROOT_DIR/worker/jobs/schema.d/202611062026-bh-9154-review-counts.sql"
TABLE="$ROOT_DIR/worker/jobs/test/route-table.d/bh-9154-review-counts.txt"
PANEL="$ROOT_DIR/console-ui/src/screens/ReviewCountsPanel.js"
SCREEN="$ROOT_DIR/console-ui/src/screens/LeadReviews.js"

for f in "$ROUTE" "$RULE" "$MOVER" "$SCHEMA" "$TABLE" "$PANEL" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
grep -q '<${ReviewCountsPanel}/>' "$SCREEN" && ok || bad "the panel is not mounted on the Lead reviews screen"
grep -q 'CREATE INDEX IF NOT EXISTS idx_review_counts_daily_project' "$SCHEMA" && ok || bad "no project index in the fragment"

command -v node >/dev/null 2>&1 || { echo "review-counts: SKIPPED the node half — node is not installed on this box"; echo "review-counts: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 2: the pure half, driven -----------------------------------------------
OUT=$(node --input-type=module -e "
import { kindMap, shapeDays, REVIEW_KINDS } from '$ROUTE';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const row = (v) => new Map([['review_counts.kind_map', { value: v }]]);
eq('kinds', REVIEW_KINDS, ['lens', 'fix-rereview', 'lead', 'conductor', 'autopilot', 'rescue', 'resolver']);
eq('map-row', kindMap(row('[{\"kind\":\"lead\",\"stage\":\"x\"}]')), [{ kind: 'lead', stage: 'x' }]);
eq('map-bad-kind', kindMap(row('[{\"kind\":\"nope\",\"stage\":\"x\"}]')).length > 1, true);
eq('map-junk', kindMap(row('not json')).length > 1, true);
eq('map-absent', kindMap(new Map()).some((r) => r.kind === 'lead'), true);
const d = shapeDays([
  { day: '2026-11-05', kind: 'lead', n: 2, merged_prs: null, rebinds: null },
  { day: '2026-11-05', kind: 'total', n: 2, merged_prs: 0, rebinds: 1 },
  { day: '2026-11-06', kind: 'total', n: 6, merged_prs: 3, rebinds: 0 },
], ['fix-rereview']);
eq('order', d.map((x) => x.day), ['2026-11-06', '2026-11-05']);
eq('unmapped-null', d[1].kinds['fix-rereview'], null);
eq('mapped-zero', d[0].kinds.lens, 0);
eq('per-merged', d[0].per_merged, 2);
eq('per-merged-none', d[1].per_merged, null);
eq('rebinds', d[1].rebinds, 1);
" 2>&1)
while IFS= read -r line; do
  case "$line" in ok\ *) ok ;; *) bad "pure: $line" ;; esac
done <<<"$OUT"

# --- 3: the node suites -----------------------------------------------------
if [ -d "$ROOT_DIR/worker/jobs/node_modules" ] || [ -f "$ROOT_DIR/worker/jobs/package-lock.json" ]; then
  if (cd "$ROOT_DIR/worker/jobs" && node --test test/review-counts.bh-9154.test.js >/dev/null 2>&1); then ok; else bad "worker/jobs/test/review-counts.bh-9154.test.js is red"; fi
fi
if [ -d "$ROOT_DIR/console-ui/node_modules/preact" ]; then
  if (cd "$ROOT_DIR/console-ui" && node --test tests/review-counts.bh-9154.test.js >/dev/null 2>&1); then ok; else bad "console-ui/tests/review-counts.bh-9154.test.js is red"; fi
else
  echo "review-counts: console node suite SKIPPED — console-ui/node_modules is not installed"
fi

echo "review-counts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
