#!/bin/bash
# tests/mcp-pool-status.bh-7709-test.sh — BH-7709: the pool_status MCP tool.
# Thin wrapper over mcp/test/pool-status.test.mjs, which loads the REAL
# registry and calls the tool through the real consoleFetch against the stub
# console, with a fetch recorder proving zero calls off the stub; and over
# worker/jobs/test/pool-tick.bh-7709.test.js, which drives POST
# /api/pool/tick-summary and GET /api/pool/status on the real worker, runs the
# lane on the fixture log and feeds the worker's answer to the tool.
# It fails when node reports 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-pool-status.bh-7709-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
command -v node >/dev/null 2>&1 || { echo "mcp-pool-status.bh-7709-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/pool-status.mjs" \
           "$DIR/mcp/tools/lib/schema.mjs" \
           "$DIR/mcp/test/pool-status.test.mjs" \
           "$DIR/mcp/test/fixtures/pool-status.bh-7709.json" \
           "$DIR/bin/pool-tick-summary.sh" \
           "$DIR/tests/fixtures/pool-tick-summary.bh-7709/fly-pool.log" \
           "$DIR/worker/jobs/src/routes/pool-tick.js" \
           "$DIR/worker/jobs/test/pool-tick.bh-7709.test.js" \
           "$DIR/worker/jobs/test/route-table.d/bh-7709-pool-tick.txt" \
           "$DIR/worker/jobs/schema.d/202610211310-bh-7709-pool-tick-summary.sql"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-pool-status.bh-7709-test: missing $SRC"; exit 1; }
done

worker_catalogs "$DIR" || exit 1
cd "$DIR" || exit 1
# Run each file directly, not under --test: --test reports the file itself as
# a passing test, so an emptied file would read "1 passed".
TOTAL=0
for F in mcp/test/pool-status.test.mjs worker/jobs/test/pool-tick.bh-7709.test.js; do
  LOG="$T/$(basename "$F").log"
  node --test-reporter=spec "$F" >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: mcp-pool-status.bh-7709-test: $F node rc=$RC"; exit 1; fi
  if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: mcp-pool-status.bh-7709-test: $F has no test summary"; exit 1; fi
  [ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: mcp-pool-status.bh-7709-test: $F 0 tests passed"; exit 1; }
  [ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: mcp-pool-status.bh-7709-test: $F $SKIPPED test(s) SKIPPED"; exit 1; }
  TOTAL=$((TOTAL + PASSED))
done
echo "mcp-pool-status.bh-7709-test: $TOTAL passed, 0 skipped"
