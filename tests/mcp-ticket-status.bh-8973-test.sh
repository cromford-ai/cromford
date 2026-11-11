#!/bin/bash
# tests/mcp-ticket-status.bh-8973-test.sh — BH-8973 (C0): the ticket_status and
# stuck_tickets MCP tools. Thin wrapper over
# worker/jobs/test/ticket-status.bh-8973.test.js, which drives GET
# /api/ticket-status and /api/ticket-status/stuck through the real worker.fetch
# over the composed schema (states, waits, the stuck knob, wrong tenant, EXPLAIN
# at volume, statements per call), and over mcp/test/ticket-status.bh-8973.test.mjs,
# which loads the REAL registry and calls the tools through the real
# consoleFetch and githubFetch against two stubs, with a fetch recorder.
# It fails when node reports 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-ticket-status.bh-8973-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
command -v node >/dev/null 2>&1 || { echo "mcp-ticket-status.bh-8973-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/ticket-status.mjs" \
           "$DIR/mcp/lib/github.mjs" \
           "$DIR/mcp/test/ticket-status.bh-8973.test.mjs" \
           "$DIR/mcp/test/fixtures/ticket-status.bh-8973.json" \
           "$DIR/worker/jobs/src/routes/ticket-status.js" \
           "$DIR/worker/jobs/src/lib/core.d/bh-8973-ticket-status.js" \
           "$DIR/worker/jobs/test/ticket-status.bh-8973.test.js" \
           "$DIR/worker/jobs/test/route-table.d/bh-8973-ticket-status.txt" \
           "$DIR/worker/jobs/schema.d/202611110521-bh-8973-ticket-status.sql"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-ticket-status.bh-8973-test: missing $SRC"; exit 1; }
done

worker_catalogs "$DIR" || exit 1
# routes/llm-sites.js imports catalog/context-budgets.json (git-ignored, BH-6487).
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { echo "FAIL: mcp-ticket-status.bh-8973-test: cannot compose catalog/context-budgets.json"; exit 1; }
cd "$DIR" || exit 1
# Run each file directly, not under --test: --test reports the file itself as
# a passing test, so an emptied file would read "1 passed".
TOTAL=0
for F in mcp/test/ticket-status.bh-8973.test.mjs worker/jobs/test/ticket-status.bh-8973.test.js; do
  LOG="$T/$(basename "$F").log"
  node --test-reporter=spec "$F" >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: mcp-ticket-status.bh-8973-test: $F node rc=$RC"; exit 1; fi
  if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: mcp-ticket-status.bh-8973-test: $F has no test summary"; exit 1; fi
  [ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: mcp-ticket-status.bh-8973-test: $F 0 tests passed"; exit 1; }
  [ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: mcp-ticket-status.bh-8973-test: $F $SKIPPED test(s) SKIPPED"; exit 1; }
  TOTAL=$((TOTAL + PASSED))
done
echo "mcp-ticket-status.bh-8973-test: $TOTAL passed, 0 skipped"
