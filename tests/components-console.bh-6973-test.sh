#!/bin/bash
# tests/components-console.bh-6973-test.sh — the console Components screen and
# the Alerts component filter (BH-6973).
#
# The behaviour is proved by node --test in
# console-ui/tests/components-screen.bh-6973.test.js. This file names the new
# sources by path for the impact lane and the orphan ratchet, drives the pure
# half for real, and checks the screen's wiring:
#   1. lib/components.js, DRIVEN: names skip NULL, the 24 h window edge, the
#      "200+" rule, tickets need a non-null issue, a failed read is null not 0.
#   2. Components.js uses the shared SortableTable and is routed in app.js.
#   3. the node suite, run when the console-ui dependencies are installed.
# Run from anywhere: tests/components-console.bh-6973-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/components.js"
SCREEN="$DIR/console-ui/src/screens/Components.js"
APP="$DIR/console-ui/src/app.js"

for f in "$LIB" "$SCREEN" "$APP"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "components-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { componentNames, shapeComponentRow, countLabel, countSortValue, componentAlertsHref, decisionsHref }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
// determinism: ok a literal epoch, never the wall clock.
const NOW = Date.parse('2026-10-17T12:00:00Z');
const at = (s) => new Date(NOW - s * 1000).toISOString();
const D = 86400;

const n = componentNames({ alerts: [{ component: 'triage' }, { component: null }, { component: 'alerts-groom' }, { component: 'triage' }], truncated: true });
eq('names',        n.names, ['alerts-groom', 'triage']);
eq('unstamped',    n.unstamped, 1);
eq('names-cut',    n.truncated, true);

const rows = [
  { verdict: 'ticket', issue: 42, at: at(10) },
  { verdict: 'ticket', issue: null, at: at(D) },
  { verdict: 'escalate', issue: 7, at: at(D + 1) },
  { verdict: 'park', issue: null, at: 'bad' }
];
const r = shapeComponentRow('triage', { alerts: [{}, {}] }, { decisions: rows, truncated: false }, NOW);
eq('open',         r.open, 2);
eq('last-run',     r.lastRunAt, at(10));
eq('in-24h-edge',  r.decisions24h, 2);
eq('tickets',      r.tickets, 1);
const cutOld = shapeComponentRow('t', { alerts: [] }, { decisions: rows, truncated: true }, NOW);
eq('cut-old-exact', countLabel(cutOld.decisions24h, cutOld.decisions24hMore), 2);
const cutNew = shapeComponentRow('t', { alerts: [] }, { decisions: rows.slice(0, 2), truncated: true }, NOW);
eq('cut-new-plus', countLabel(cutNew.decisions24h, cutNew.decisions24hMore), '2+');
const failed = shapeComponentRow('t', null, null, NOW, { alertsError: 'http_502', decisionsError: 'http_502' });
eq('failed-null',  [failed.open, failed.decisions24h, failed.tickets], [null, null, null]);
eq('cut-sorts-up', countSortValue(500, true) > countSortValue(500, false), true);
eq('href',         componentAlertsHref('triage'), '/alerts?component=triage');
eq('dec-href',     decisionsHref('a/2'), '/alerts/decisions/a%2F2');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's wiring --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Components.js must use the shared SortableTable"
grep -q "\['/components', ComponentsScreen\]" "$APP" && ok || bad "app.js must route /components"
grep -q "\['/alerts/decisions/:id', AlertDecisionsScreen\]" "$APP" && ok || bad "app.js must route /alerts/decisions/:id"

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "components-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/components-screen.bh-6973.test.js 2>&1); then ok
  else bad "console-ui/tests/components-screen.bh-6973.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "components-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
