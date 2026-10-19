#!/bin/bash
# tests/build-order-console.bh-6980-test.sh — BH-6980 (BH-6547.4): the
# build-order screen in the console, /build-order.
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/build-order.bh-6980.test.js (the console-ui CI job). This
# file is the part the impact lane and the orphan ratchet can SEE (the
# box-switches-console.bh-5934 pattern):
#   1. console-ui/src/lib/build-order.js, DRIVEN: the node state rule (B1, B2)
#      and the layers of a chain and a cycle (B7).
#   2. app.js routes /build-order to BuildOrderScreen, and Kanban.js links to it.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/build-order-console.bh-6980-test.sh   (exit 0 = all pass)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$REPO/console-ui/src/lib/build-order.js"
SCREEN="$REPO/console-ui/src/screens/BuildOrder.js"
APP="$REPO/console-ui/src/app.js"
KANBAN="$REPO/console-ui/src/screens/Kanban.js"
for f in "$LIB" "$SCREEN" "$APP" "$KANBAN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "build-order-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { nodeState, buildOrderGraph } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const v = (ticket, ready, reason = '') => ({ ticket, ready, reason });
const g = (verdicts, edges) => buildOrderGraph({ project: 'cromford',
  ready: { at: '2026-10-18T21:00:00Z', mode: 'shadow', candidates: verdicts.length, complete: true, verdicts },
  edges: { edges: edges.map(([parent, child]) => ({ parent, child, kind: 'hard' })) }, pipeline: { columns: {} } });
eq('B1 ready',   nodeState({ verdict: v(1, 'yes') }), { state: 'ready', label: 'ready', reason: '' });
eq('B2 waiting', nodeState({ verdict: v(2, 'no', 'parent #6979 open') }),
                 { state: 'waiting', label: 'waiting on #6979', reason: 'parent #6979 open' });
eq('B2 near miss', nodeState({ verdict: v(2, 'no', 'files claimed by #12') }).label, 'waiting');
eq('B7 chain',   g([v(1, 'yes'), v(2, 'yes'), v(3, 'yes')], [[1, 2], [2, 3]]).layers.map((l) => l.map((n) => n.n)), [[1], [2], [3]]);
eq('B7 cycle',   g([v(4, 'yes'), v(5, 'yes')], [[4, 5], [5, 4]]).nodes.map((n) => n.cycle), [true, true]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the route, the tab and the entry link ---------------------------------
grep -qF "['/build-order', BuildOrderScreen]," "$APP" && ok || bad "app.js ROUTES must route /build-order to BuildOrderScreen"
grep -qF "import { BuildOrderScreen } from './screens/BuildOrder.js';" "$APP" && ok || bad "app.js must import BuildOrderScreen"
grep -qF "p === '/build-order'" "$APP" && ok || bad "the KANBAN tab must light on /build-order"
grep -qF 'to="/build-order"' "$KANBAN" && ok || bad "Kanban.js must link to /build-order"
grep -q "from '../lib/build-order.js'" "$SCREEN" && ok || bad "BuildOrder.js must build the graph through lib/build-order.js"

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$REPO/console-ui/node_modules/preact-render-to-string" ]; then
  echo "build-order-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$REPO/console-ui" && node --test tests/build-order.bh-6980.test.js 2>&1); then ok
  else bad "console-ui/tests/build-order.bh-6980.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "build-order-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
