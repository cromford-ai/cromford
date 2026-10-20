#!/bin/bash
# tests/mcp-box-health.bh-7710-test.sh — BH-7710: the box_health and
# box_restart MCP tools. Thin wrapper over mcp/test/box-health.bh-7710.test.mjs,
# which loads the REAL registry and calls both tools through the real
# consoleFetch against the stub console, with fetch and child_process
# recorders proving zero calls off the stub; and over
# worker/jobs/test/box-ssh.bh-7710.test.js, which drives POST /api/box-ssh and
# GET /api/box-health on the real worker and feeds that answer to the tools.
# It fails when node reports 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-box-health.bh-7710-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "mcp-box-health.bh-7710-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/box-health.mjs" \
           "$DIR/mcp/tools/lib/schema.mjs" \
           "$DIR/mcp/test/box-health.bh-7710.test.mjs" \
           "$DIR/mcp/test/fixtures/box-health.bh-7710.json" \
           "$DIR/worker/jobs/src/routes/box-ssh.js" \
           "$DIR/worker/jobs/test/box-ssh.bh-7710.test.js" \
           "$DIR/worker/jobs/test/fixtures/box-ssh-post.bh-7710.json" \
           "$DIR/worker/jobs/schema.d/202610201507-bh-7710-box-ssh-state.sql"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-box-health.bh-7710-test: missing $SRC"; exit 1; }
done

cd "$DIR" || exit 1
# Run each file directly, not under --test: --test reports the file itself as
# a passing test, so an emptied file would read "1 passed".
TOTAL=0
for F in mcp/test/box-health.bh-7710.test.mjs worker/jobs/test/box-ssh.bh-7710.test.js; do
  LOG="$T/$(basename "$F").log"
  node --test-reporter=spec "$F" >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: mcp-box-health.bh-7710-test: $F node rc=$RC"; exit 1; fi
  if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: mcp-box-health.bh-7710-test: $F has no test summary"; exit 1; fi
  [ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: mcp-box-health.bh-7710-test: $F 0 tests passed"; exit 1; }
  [ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: mcp-box-health.bh-7710-test: $F $SKIPPED test(s) SKIPPED"; exit 1; }
  TOTAL=$((TOTAL + PASSED))
done
echo "mcp-box-health.bh-7710-test: $TOTAL passed, 0 skipped"
