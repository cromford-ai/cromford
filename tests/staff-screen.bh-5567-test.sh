#!/bin/bash
# tests/staff-screen.bh-5567-test.sh — BH-5567 (BH-5556.10): the console /staff
# screen and its three worker reads. A wrapper the impact lane and the orphan
# ratchet can SEE: it names every new source by path and runs the suites that
# prove them.
#
#   1. worker/jobs/test/staff-screen.test.js and route-table.test.js: the REAL
#      worker.fetch over the REAL worker/jobs/schema.sql (node:sqlite D1 shim).
#      Fails on 0 passing tests or any skipped one.
#   2. console-ui/src/lib/staff.js, DRIVEN: the kill flag names, and the
#      unknown kill state on a failed flags read.
#   3. Staff.js uses the shared SortableTable and the in-app Modal, and calls
#      no native dialog.
#   4. console-ui/tests/staff-screen.bh-5567.test.js, run when the console-ui
#      dependencies are installed. The playwright drive
#      (console-ui/tests/drive/staff-drive.mjs, `npm run drive:staff`) is not
#      run here: it needs a browser.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-screen.bh-5567-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: staff-screen.bh-5567-test: $1"; }

ROUTES_SRC="$DIR/worker/jobs/src/routes/staff-screen.js"
SCREEN="$DIR/console-ui/src/screens/Staff.js"
LIB="$DIR/console-ui/src/lib/staff.js"
for SRC in "$ROUTES_SRC" "$SCREEN" "$LIB" \
           "$DIR/worker/jobs/schema.d/0021-bh-5567-staff-screen.sql" \
           "$DIR/worker/jobs/test/route-table.d/745-staff-screen.txt" \
           "$DIR/worker/jobs/test/staff-screen.test.js" \
           "$DIR/worker/jobs/schema.sql" "$DIR/worker/jobs/src/index.js" \
           "$DIR/console-ui/src/app.js" "$DIR/console-ui/src/api.js" \
           "$DIR/console-ui/tests/staff-screen.bh-5567.test.js" \
           "$DIR/console-ui/tests/drive/staff-drive.mjs"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

command -v node >/dev/null 2>&1 || { echo "staff-screen.bh-5567-test: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the worker suites ----------------------------------------------------
if node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null; then
  LOG="$T/worker.log"
  (cd "$DIR/worker/jobs" && node --test --test-reporter=spec test/staff-screen.test.js test/route-table.test.js) >"$LOG" 2>&1
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
  echo "staff-screen.bh-5567-test: worker suite SKIPPED — this node has no node:sqlite"
fi

# --- 2: the lib, driven -------------------------------------------------------
OUT=$(node --input-type=module -e "
import { killFlagName, killState, killSetBody, KILL_ALL, na } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('kill-name',     killFlagName(' Watchman '), 'staff-kill-watchman');
eq('kill-archie',   killFlagName('archie'), null);
eq('kill-all',      killFlagName('all'), null);
eq('kill-path',     killFlagName('../x'), null);
eq('kill-all-name', KILL_ALL, 'staff-kill-all');
eq('body-foreign',  killSetBody('paused-project-3', 'r'), null);
eq('state-failed',  killState(null, 'staff-kill-clerk'), 'unknown');
eq('state-on',      killState({ flags: [{ name: 'staff-kill-clerk', scope: 'fleet', cleared_at: null }] }, 'staff-kill-clerk'), 'on');
eq('na-null',       na(null), 'n/a');
eq('na-zero',       na(0), '0');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the screen's shape ----------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Staff.js must use the shared SortableTable"
grep -q "from '../ui/Modal.js'" "$SCREEN" && ok || bad "Staff.js must confirm the kill switch in the in-app Modal"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog call in the staff screen"
else
  ok
fi

# --- 4: the console node suite ------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-screen.bh-5567-test: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  CLOG="$T/console.log"
  if (cd "$DIR/console-ui" && node --test tests/staff-screen.bh-5567.test.js) >"$CLOG" 2>&1; then ok
  else bad "console-ui/tests/staff-screen.bh-5567.test.js failed:"; grep -E '^not ok|Error' "$CLOG" | head -20
  fi
fi

echo "staff-screen.bh-5567-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
