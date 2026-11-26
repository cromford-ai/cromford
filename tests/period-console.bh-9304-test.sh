#!/bin/bash
# tests/period-console.bh-9304-test.sh — the shared period core (BH-9304,
# BH-9120.0): the period libraries, the picker, the chart, the report seams,
# the knobs route and its seed rows, and GET /api/jobs?from=&to=.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by four node suites
# (named below). This file names every new source by path, so the impact lane
# and the orphan ratchet can see them, drives the two pure range parsers for
# real, and runs the node suites when their dependencies are installed.
# Run from anywhere: tests/period-console.bh-9304-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# worker/jobs/src/index.js imports the git-ignored catalog renders, so compose
# them before the worker node suites load it (BH-6452, BH-6540). routes/llm-sites.js
# also imports catalog/context-budgets.json (BH-6487), the third render.
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

UI_LIB="$DIR/console-ui/src/lib/period.js"
PICKER="$DIR/console-ui/src/ui/PeriodPicker.js"
CHART="$DIR/console-ui/src/ui/PeriodChart.js"
CSS="$DIR/console-ui/src/period-picker.css"
PAGES_LIB="$DIR/console-ui/functions/_lib/period.js"
SEAMS="$DIR/console-ui/src/screens/period-report.d"
W_LIB="$DIR/worker/jobs/src/lib/period.js"
W_ROUTE="$DIR/worker/jobs/src/routes/period.js"
W_FRAG="$DIR/worker/jobs/test/route-table.d/bh-9304-period.txt"
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-9304-period-knobs.sql 2>/dev/null | head -1)

for f in "$UI_LIB" "$PICKER" "$CHART" "$CSS" "$PAGES_LIB" "$W_LIB" "$W_ROUTE" "$W_FRAG" "$SEED" \
  "$SEAMS/index.js" "$SEAMS/costs.js" "$SEAMS/outcomes.js" "$SEAMS/dora.js" "$SEAMS/ci.js" \
  "$SEAMS/utilization.js" "$SEAMS/jobs.js" "$SEAMS/lanes.js" "$SEAMS/history.js" "$SEAMS/commands.js"; do
  [ -n "$f" ] && [ -f "$f" ] && ok || bad "missing ${f:-the bh-9304 period-knobs seed fragment}"
done

# The seed fragment holds the four rows with the ticket's values.
for row in "'mc.period.max_range_days','366'" "'mc.period.csv_row_cap','100000'" \
  "'mc.period.default_preset','last_7_days'" "'mc.period.max_buckets','2000'"; do
  grep -qF "$row" "${SEED:-/dev/null}" && ok || bad "seed row $row"
done
grep -q '^GET /api/period/knobs$' "$W_FRAG" && ok || bad "the route fragment names GET /api/period/knobs"

command -v node >/dev/null 2>&1 || { echo "period-console: SKIPPED the node part: node is not installed on this box"; echo "period-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- the two range parsers, driven: the worker's and the Pages copy agree ----
OUT=$(node --input-type=module -e "
import * as W from '$W_LIB';
import * as P from '$PAGES_LIB';
import * as U from '$UI_LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const now = Date.parse('2026-11-14T12:00:00Z');
const u = (qs) => new URL('https://h/x?' + qs);
for (const L of [W, P]) {
  eq('range', L.parseRange(u('from=2026-10-01&to=2026-10-08'), {}, now), { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' });
  eq('semicolon', L.parseRange(u('from=2026-10-01%3BDROP'), {}, now).error, 'from is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)');
  eq('none', L.parseRange(u('project=x'), {}, now), null);
  eq('bucket', L.bucketExpr('hour;--', 'created_at'), null);
}
eq('ui-preset', U.resolvePreset('last_month', Date.parse('2026-01-15T00:00:00Z')), { from: '2025-12-01T00:00:00Z', to: '2026-01-01T00:00:00Z' });
eq('ui-with', U.withPeriod('/costs', '?from=2026-10-01&agent=x'), '/costs?from=2026-10-01');
" 2>&1)
while IFS= read -r line; do
  case "$line" in ok\ *) ok ;; *) bad "driven: $line" ;; esac
done <<<"$OUT"

# --- the node suites ----------------------------------------------------------
# The worker suites need no install. The console-ui suites need preact.
(cd "$DIR/worker/jobs" && node --test test/period.bh-9304.test.js test/jobs-period.bh-9304.test.js >/dev/null 2>&1) && ok || bad "worker/jobs period node suites"
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  (cd "$DIR/console-ui" && node --test tests/period.bh-9304.test.js tests/period-picker.bh-9304.test.js >/dev/null 2>&1) && ok || bad "console-ui period node suites"
else
  echo "period-console: skipped the console-ui node suites: console-ui dependencies are not installed"
fi

echo "period-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
