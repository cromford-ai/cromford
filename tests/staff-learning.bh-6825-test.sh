#!/bin/bash
# tests/staff-learning.bh-6825-test.sh — BH-6825 (Staff in Mission Control 4/4):
# the LEARNING panel on /staff/:agent and its three worker routes. A wrapper the
# impact lane and the orphan ratchet can SEE: it names every new source by path
# and runs the suites that prove them.
#
#   1. worker/jobs/test/staff-learning.bh-6825.test.js: the REAL worker.fetch
#      over the composed jobs schema (node:sqlite D1 shim), with EXPLAIN QUERY
#      PLAN on seeded volume. Fails on 0 passing tests or any skipped one.
#   2. console-ui/src/lib/staff-learning.js, DRIVEN: no outcome is n/a (never
#      0%), a blank reason builds no body, a failed read is null.
#   3. the panel uses the shared SortableTable and the in-app Modal and calls
#      no native dialog; the coord row requires a reason.
#   4. console-ui/tests/staff-learning.bh-6825.test.js, run when the console-ui
#      dependencies are installed.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-learning.bh-6825-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: staff-learning.bh-6825-test: $1"; }

ROUTES_SRC="$DIR/worker/jobs/src/routes/staff-learning.js"
PANEL="$DIR/console-ui/src/screens/staff/agent-learning.js"
LIB="$DIR/console-ui/src/lib/staff-learning.js"
FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/6825-staff-promotions.js"
for SRC in "$ROUTES_SRC" "$PANEL" "$LIB" "$FRAG" \
           "$DIR/worker/jobs/schema.d/202610170334-bh-6825-staff-learning.sql" \
           "$DIR/worker/jobs/test/route-table.d/787-staff-learning.txt" \
           "$DIR/worker/jobs/test/staff-learning.bh-6825.test.js" \
           "$DIR/worker/jobs/src/routes/retention.js" \
           "$DIR/console-ui/src/screens/Staff.js" "$DIR/console-ui/src/api.js" \
           "$DIR/console-ui/tests/staff-learning.bh-6825.test.js"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

command -v node >/dev/null 2>&1 || { echo "staff-learning.bh-6825-test: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the worker suite -----------------------------------------------------
if node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null; then
  LOG="$T/worker.log"
  (cd "$DIR/worker/jobs" && node --test --test-reporter=spec test/staff-learning.bh-6825.test.js) >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; bad "worker node --test rc=$RC"
  elif [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; bad "worker: no test summary"
  elif [ "$PASSED" -eq 0 ]; then cat "$LOG"; bad "worker: 0 tests passed"
  elif [ "$SKIPPED" != 0 ]; then cat "$LOG"; bad "worker: $SKIPPED test(s) SKIPPED"
  else ok
  fi
else
  echo "staff-learning.bh-6825-test: worker suite SKIPPED — this node has no node:sqlite"
fi

# --- 2: the lib, driven --------------------------------------------------------
OUT=$(node --input-type=module -e "
import { pct, decideBody, learningState, outcomeHref } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('pct-null',      pct(null), 'n/a (no outcomes)');
eq('pct-zero',      pct(0), '0%');
eq('pct-half',      pct(0.5), '50%');
eq('body-blank',    decideBody({ id: 4, decision: 'approve', reason: '  ' }), null);
eq('body-verb',     decideBody({ id: 4, decision: 'applied', reason: 'r' }), null);
eq('body-ok',       decideBody({ id: 4, decision: 'void', reason: ' r ' }), { id: 4, decision: 'void', reason: 'r' });
eq('state-failed',  learningState({ error: 'agent not found' }), null);
eq('href-removed',  outcomeHref(null), null);
eq('href',          outcomeHref(12), '/staff/finding/12');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the panel's shape --------------------------------------------------------
grep -q "from '../../ui/SortableTable.js'" "$PANEL" && ok || bad "agent-learning.js must use the shared SortableTable"
grep -q "from '../../ui/Modal.js'" "$PANEL" && ok || bad "agent-learning.js must decide in the in-app Modal"
grep -q "needsReason: true" "$FRAG" && ok || bad "the coord row in $FRAG must require a reason"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(confirm|alert|prompt)[[:space:]]*\( ]] || [[ "$CODE" =~ window\.(confirm|alert|prompt) ]]; then
  bad "a native dialog call in the LEARNING panel"
else
  ok
fi

# --- 4: the console node suite -----------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-learning.bh-6825-test: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  CLOG="$T/console.log"
  if (cd "$DIR/console-ui" && node --test tests/staff-learning.bh-6825.test.js) >"$CLOG" 2>&1; then ok
  else bad "console-ui/tests/staff-learning.bh-6825.test.js failed:"; grep -E '^not ok|Error' "$CLOG" | head -20
  fi
fi

echo "staff-learning.bh-6825-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
