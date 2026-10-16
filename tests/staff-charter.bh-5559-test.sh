#!/bin/bash
# tests/staff-charter.bh-5559-test.sh — BH-5559 (BH-5556.2): the staff charter
# and autonomy tables. Thin wrapper over worker/jobs/test/staff-charter.test.js,
# which drives the REAL worker.fetch over the REAL worker/jobs/schema.sql (the
# node:sqlite D1 shim). It fails when node reports 0 passing tests or any
# skipped one: a suite that skipped gates nothing.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-charter.bh-5559-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v node >/dev/null 2>&1 || { echo "staff-charter.bh-5559-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/worker/jobs/src/routes/staff.js" "$DIR/worker/jobs/test/staff-charter.test.js" \
           "$DIR/worker/jobs/test/route-table.d/732-staff.txt" "$DIR/worker/jobs/schema.sql" \
           "$DIR/worker/jobs/src/index.js" "$DIR/agent-core/schema/charter.schema.json"; do
  [ -r "$SRC" ] || { echo "FAIL: staff-charter.bh-5559-test: missing $SRC"; exit 1; }
done

node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null || {
  echo "staff-charter.bh-5559-test: SKIPPED — this node has no node:sqlite"; exit 0; }

LOG="$T/node.log"
cd "$DIR/worker/jobs" || exit 1
node --test --test-reporter=spec test/staff-charter.test.js test/route-table.test.js >"$LOG" 2>&1
RC=$?
PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: staff-charter.bh-5559-test: node --test rc=$RC"; exit 1; fi
if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: staff-charter.bh-5559-test: no test summary — node's reporter changed shape"; exit 1; fi
[ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: staff-charter.bh-5559-test: 0 tests passed — the suite did not run"; exit 1; }
[ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: staff-charter.bh-5559-test: $SKIPPED test(s) SKIPPED"; exit 1; }
echo "staff-charter.bh-5559-test: $PASSED passed, 0 skipped"
