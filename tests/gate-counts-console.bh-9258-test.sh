#!/bin/bash
# tests/gate-counts-console.bh-9258-test.sh — the console SELECTION GATES TODAY
# section on /p/<project> (BH-9258, #9061 Fix 4).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/gate-counts.bh-9258.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the new source by path, drives its pure half, and holds the screen
# to the rules a reviewer would otherwise check by eye (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. GateCountsPanel.js, DRIVEN: shareLine gives "n of gates (p%)" and n/a
#      when no gate ran; gatesOf takes only a plain gates_today object; the
#      columns are the six the plan names, in order.
#   2. the screen sorts through the shared SortableTable, is mounted on the
#      Project page, reads api.poolStatus, and never calls a native dialog.
#   3. the node suite console-ui/tests/gate-counts.bh-9258.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/gate-counts-console.bh-9258-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/GateCountsPanel.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"
API="$DIR/console-ui/src/api.js"

for f in "$SCREEN" "$PROJECT" "$API"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen's shape (no node needed) ---------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "GateCountsPanel.js must use the shared SortableTable"
grep -q "api.poolStatus(project)" "$SCREEN" && ok || bad "GateCountsPanel.js must read api.poolStatus(project)"
grep -q "Skeleton" "$SCREEN" && ok || bad "GateCountsPanel.js must show a Skeleton while loading"
grep -q "ErrorBox" "$SCREEN" && ok || bad "GateCountsPanel.js must show an ErrorBox on a failed read"
grep -q "import GateCountsPanel from './GateCountsPanel.js'" "$PROJECT" && ok || bad "Project.js must import GateCountsPanel"
grep -q '<\${GateCountsPanel} project=\${project}/>' "$PROJECT" && ok || bad "Project.js must mount the GateCountsPanel section"
grep -q "poolStatus: (project) => get(coordPath(\`/api/pool/status?project=" "$API" && ok || bad "api.js must carry poolStatus over the coord path"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the SELECTION GATES TODAY screen"
else
  ok
fi

command -v node >/dev/null 2>&1 || { echo "gate-counts-console: node checks SKIPPED — node is not installed on this box"; echo "gate-counts-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "gate-counts-console: node checks SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
  echo "gate-counts-console: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# --- 1: the pure half, driven -----------------------------------------------
OUT=$(node --input-type=module -e "
import { shareLine, gatesOf, GATE_COLUMNS } from '$SCREEN';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('share-count',   shareLine({ gates: 45, rc1_unattributed: 27 }), 'unattributed: 27 of 45 (60%)');
eq('share-zero',    shareLine({ gates: 0, rc1_unattributed: 0 }), 'unattributed: n/a');
eq('share-null',    shareLine(null), 'unattributed: n/a');
eq('share-junk',    shareLine({ gates: '3', rc1_unattributed: 1 }), 'unattributed: n/a');
eq('gates-plain',   gatesOf({ gates_today: { day: '2026-11-08', gates: 1 } }), { day: '2026-11-08', gates: 1 });
eq('gates-null',    gatesOf({ gates_today: null }), null);
eq('gates-array',   gatesOf({ gates_today: [1] }), null);
eq('gates-none',    gatesOf(null), null);
eq('columns',       GATE_COLUMNS.map(([k]) => k), ['day', 'gates', 'rc0', 'rc1_attributed', 'rc1_unattributed', 'could_not_run']);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suite, driven -----------------------------------------------
if NOUT=$(cd "$DIR/console-ui" && node --test tests/gate-counts.bh-9258.test.js 2>&1); then ok
else bad "console-ui/tests/gate-counts.bh-9258.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "gate-counts-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
