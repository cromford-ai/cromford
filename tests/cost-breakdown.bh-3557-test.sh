#!/bin/bash
# tests/cost-breakdown.bh-3557-test.sh — the SPEND BREAKDOWN on /costs and the
# stage-less lane null rule (BH-3557).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# worker/jobs/test/cost-breakdown.bh-3557.test.js,
# worker/jobs/test/lanes-stageless-cost.bh-3557.test.js,
# console-ui/tests/cost-breakdown.bh-3557.test.js and
# console-ui/tests/settings-stageless-cost.bh-3557.test.js. This file is what
# the impact lane and the orphan ratchet can SEE: it names the three new
# sources by path, drives the console lib's pure half, and runs the node suites
# when their dependencies are there (the cost-breaker-console.bh-2331 pattern).
#
#   1. console-ui/src/lib/cost-breakdown.js, DRIVEN: billing labels, the
#      present-empty (IS NULL) filter, and every view ending at the rows.
#   2. the route is registered once and has its route-table fragment; the
#      screen uses the shared SortableTable and is mounted on /costs.
#   3. the four node suites, run for real.
# Run from anywhere: tests/cost-breakdown.bh-3557-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/cost-breakdown.js"
LIB="$DIR/console-ui/src/lib/cost-breakdown.js"
SCREEN="$DIR/console-ui/src/screens/CostBreakdown.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"
INDEX="$DIR/worker/jobs/src/index.js"

for f in "$ROUTE" "$LIB" "$SCREEN" "$COSTS" "$INDEX"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "cost-breakdown: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
import { billingLabel, breakdownRows, filtersFor, childRequest, BREAKDOWN_VIEWS, windowParams }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('bill-sub',   billingLabel('subscription'), 'API-equivalent, not cash');
eq('bill-met',   billingLabel('metered'), 'cash');
eq('bill-null',  billingLabel(null), 'unknown');
const [none] = breakdownRows({ groups: [{ project: null, usd: 1 }] }, ['project']);
eq('null-label', none.label, '(no project)');
eq('null-filter', filtersFor(none, ['project'], {}), { project: '' });
eq('today',      windowParams('today', Date.parse('2026-09-25T12:00:00Z')), { since: '2026-09-25T00:00:00Z' });
for (const v of BREAKDOWN_VIEWS) {
  let f = {}, d = 0, req;
  do { req = childRequest(v.key, d, { project: 'p', stage: 's', runner: 'r', model: 'm', billing_mode: 'metered', ticket: 't' }, f); f = req.filters; d++; }
  while (req.group !== 'rows' && d < 5);
  eq('view-' + v.key + '-ends-at-rows', req.group, 'rows');
}
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: wiring --------------------------------------------------------------
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-cost-breakdown.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "cost-breakdown has no route-table.d fragment (BH-4607: the fragment IS the registration)"
grep -q 'from "./routes/cost-breakdown.js"' "$INDEX" && bad "index.js hand-registers cost-breakdown: the fragment registers it (BH-4607)" || ok
grep -qx 'GET /api/metrics/cost-breakdown' "$DIR"/worker/jobs/test/route-table.d/*-cost-breakdown.txt 2>/dev/null \
  && ok || bad "no route-table fragment for GET /api/metrics/cost-breakdown"
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CostBreakdown.js must use the shared SortableTable"
grep -q '<\${CostBreakdownSection}/>' "$COSTS" && ok || bad "Costs.js must mount the SPEND BREAKDOWN section"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then bad "a native dialog in the SPEND BREAKDOWN screen"; else ok; fi

# --- 3: the node suites, driven ---------------------------------------------
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "cost-breakdown: worker suites SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/cost-breakdown.bh-3557.test.js test/lanes-stageless-cost.bh-3557.test.js 2>&1); then ok
else bad "worker suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-breakdown: console suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-breakdown.bh-3557.test.js tests/settings-stageless-cost.bh-3557.test.js 2>&1); then ok
else bad "console suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "cost-breakdown: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
