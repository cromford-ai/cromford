#!/bin/bash
# tests/mcp-lead-review.bh-7711-test.sh — BH-7711: the lead review MCP tools.
# Thin wrapper over three node suites:
#   mcp/test/lead-review.bh-7711.test.mjs        lead_review_show, _request and
#     _reset through the REAL registry and consoleFetch against the stub
#     console, and through the real `node mcp/server.mjs` for the leak checks
#   worker/jobs/test/lead-reviews-mcp.bh-7711.test.js   GET ?repo=&pr= (with
#     EXPLAIN on 5000 rows) and the stale-running reset, through worker.fetch
#   console-ui/tests/coord-lead-reviews.bh-7711.test.js   the two coord proxy
#     write rows in coord-writes.d/7711-lead-reviews.js
# It fails when a file exits non-zero, reports 0 passing tests, or skips one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-lead-review.bh-7711-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "mcp-lead-review.bh-7711-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/lead-review.mjs" \
           "$DIR/mcp/tools/lib/schema.mjs" \
           "$DIR/mcp/test/lead-review.bh-7711.test.mjs" \
           "$DIR/worker/jobs/src/routes/lead-reviews.js" \
           "$DIR/worker/jobs/test/lead-reviews-mcp.bh-7711.test.js" \
           "$DIR/console-ui/functions/_lib/coord-writes.d/7711-lead-reviews.js" \
           "$DIR/console-ui/tests/coord-lead-reviews.bh-7711.test.js"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-lead-review.bh-7711-test: missing $SRC"; exit 1; }
done

# The worker imports three generated, git-ignored catalogs: compose them first
# (as box-commands-owner.bh-5750 and the CI worker job do).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

TOTAL=0
# run_suite <dir> <file>: one node file, run directly (not under --test, which
# reports the file itself as a passing test, so an emptied file would read
# "1 passed").
run_suite() {
  local log="$T/$(basename "$2").log" rc passed skipped
  (cd "$DIR/$1" && node --test-reporter=spec "$2") >"$log" 2>&1
  rc=$?
  passed=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  skipped=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  if [ "$rc" -ne 0 ]; then cat "$log"; echo "FAIL: mcp-lead-review.bh-7711-test: $1/$2 node rc=$rc"; exit 1; fi
  if [ -z "$passed" ] || [ -z "$skipped" ]; then cat "$log"; echo "FAIL: mcp-lead-review.bh-7711-test: $1/$2 has no test summary"; exit 1; fi
  [ "$passed" -gt 0 ] || { cat "$log"; echo "FAIL: mcp-lead-review.bh-7711-test: $1/$2 passed 0 tests"; exit 1; }
  [ "$skipped" = 0 ] || { cat "$log"; echo "FAIL: mcp-lead-review.bh-7711-test: $1/$2 SKIPPED $skipped test(s)"; exit 1; }
  echo "  $1/$2: $passed passed"
  TOTAL=$((TOTAL + passed))
}

run_suite mcp test/lead-review.bh-7711.test.mjs
run_suite worker/jobs test/lead-reviews-mcp.bh-7711.test.js
run_suite console-ui tests/coord-lead-reviews.bh-7711.test.js
echo "mcp-lead-review.bh-7711-test: $TOTAL passed, 0 skipped"
