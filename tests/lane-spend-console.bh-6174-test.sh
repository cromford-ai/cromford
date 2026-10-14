#!/bin/bash
# tests/lane-spend-console.bh-6174-test.sh — the console LANE SPEND section on
# /costs (BH-6174, BH-5526 slice C4).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/lane-spend.bh-6174.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the two new sources by path, drives the pure half for real, and
# holds the screen to the rules a reviewer would otherwise check by eye (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. lib/lane-spend.js, DRIVEN: a null alert line stays null, the ceiling
#      text for each settings state, OVER CEILING before OVER ALERT, `no line`
#      when both lines are null, and the fleet switch banner only on `true`.
#   2. LaneSpend.js sorts through the shared SortableTable, is mounted on
#      /costs, and never calls a native dialog.
#   3. the node suite console-ui/tests/lane-spend.bh-6174.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/lane-spend-console.bh-6174-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/lane-spend.js"
SCREEN="$DIR/console-ui/src/screens/LaneSpend.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"

for f in "$LIB" "$SCREEN" "$COSTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "lane-spend-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { laneSpendRows, ceilingText, stateOf, switchBanner, p99Footnote } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const rows = laneSpendRows({ lanes: [
  { lane: 'fly-pool', registered: true, today_usd: 160, alert_usd: 150, ceiling_usd: 300, ceiling_state: 'armed',
    over_alert: true, over_ceiling: false },
  { lane: 'stage-review', registered: false, today_usd: 1, alert_usd: null, ceiling_usd: null, ceiling_state: 'none' } ] });
eq('rows-null-alert',  rows[1].alert_usd, null);
eq('rows-registered',  rows.map((r) => r.registered), [true, false]);
eq('rows-state',       rows.map((r) => r.state.label), ['OVER ALERT', 'no line']);
eq('rows-unread',      laneSpendRows(null), []);

eq('ceil-armed',       ceilingText({ ceiling_state: 'armed', ceiling_usd: 300 }), '\$300.00');
eq('ceil-armed-null',  ceilingText({ ceiling_state: 'armed', ceiling_usd: null }), '—');
eq('ceil-off',         ceilingText({ ceiling_state: 'off' }), 'off');
eq('ceil-zero',        ceilingText({ ceiling_state: 'zero', ceiling_raw: '0' }), '0 (none)');
eq('ceil-junk',        ceilingText({ ceiling_state: 'junk', ceiling_raw: 'abc' }), 'junk: abc');
eq('ceil-none',        ceilingText({ ceiling_state: 'none' }), '—');

eq('state-ceiling',    stateOf({ over_ceiling: true, over_alert: true, alert_usd: 1, ceiling_usd: 1 }).label, 'OVER CEILING');
eq('state-alert',      stateOf({ over_alert: true, alert_usd: 1 }).label, 'OVER ALERT');
eq('state-ok',         stateOf({ alert_usd: 5, ceiling_usd: null }).label, 'ok');
eq('state-no-line',    stateOf({ alert_usd: null, ceiling_usd: null }).label, 'no line');

eq('switch-on',        /switch\.spend-ceiling-off/.test(switchBanner({ ceiling_switch_fleet: true })), true);
eq('switch-off',       switchBanner({ ceiling_switch_fleet: false }), null);
eq('switch-null',      switchBanner({ ceiling_switch_fleet: null }), null);

eq('foot-today',       p99Footnote({ day: '2026-10-12', p99_day: '2026-10-12' }), null);
eq('foot-old',         /2026-10-11/.test(p99Footnote({ day: '2026-10-12', p99_day: '2026-10-11' })), true);
eq('foot-none',        /no p99 table/.test(p99Footnote({ day: '2026-10-12', p99_day: null })), true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "LaneSpend.js must use the shared SortableTable"
grep -q "LaneSpendSection" "$COSTS" && ok || bad "Costs.js must mount the LANE SPEND section"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the LANE SPEND screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
# console-ui/tests/lane-spend.bh-6174.test.js drives the api helper and a
# server-side render. Run here too; without the console deps it says so and skips.
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "lane-spend-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/lane-spend.bh-6174.test.js 2>&1); then ok
  else bad "console-ui/tests/lane-spend.bh-6174.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "lane-spend-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
