#!/bin/bash
# tests/client-approval-ui.bh-9901-test.sh — BH-9901 (BH-9887 slice C2): the
# console and MCP readers of the hub ledger row kind client-approval. A thin
# wrapper over two node files:
#   console-ui/tests/client-approval.bh-9901.test.js — the pure reader
#     (approvalOf, approvalMap), BuildsTable with `approvals`, and the real
#     PRScreen mounted in the fake DOM against routedFetch (V1-V9)
#   mcp/test/pr-stage-client-approval.bh-9901.test.mjs — pr_stage against the
#     stub console (M1-M7)
# Both read tests/fixtures/client-approval/ledger-row.bh-9901.json, the row
# tests/client-approval-close.bh-9901-test.sh RT1 proves the box writes. It
# fails when node reports 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/client-approval-ui.bh-9901-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "client-approval-ui.bh-9901-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite (D41).
for SRC in "$DIR/console-ui/src/lib/client-approval.js" \
           "$DIR/console-ui/src/ui/ClientApprovalTag.js" \
           "$DIR/console-ui/src/screens/PR.js" \
           "$DIR/console-ui/src/screens/Project.js" \
           "$DIR/console-ui/src/api.js" \
           "$DIR/mcp/tools/merge-queue.mjs" \
           "$DIR/console-ui/tests/client-approval.bh-9901.test.js" \
           "$DIR/mcp/test/pr-stage-client-approval.bh-9901.test.mjs" \
           "$DIR/tests/fixtures/client-approval/ledger-row.bh-9901.json"; do
  [ -r "$SRC" ] || { echo "FAIL: client-approval-ui.bh-9901-test: missing $SRC"; exit 1; }
done

TOTAL=0
# run_node <dir> <file> — node runs the file directly (not under --test, which
# reports the file itself as a passing test).
run_node() {
  local log="$T/node-${2##*/}.log" rc passed skipped
  ( cd "$DIR/$1" && node --test-reporter=spec "$2" ) >"$log" 2>&1
  rc=$?
  passed=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  skipped=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  if [ "$rc" -ne 0 ]; then cat "$log"; echo "FAIL: client-approval-ui.bh-9901-test: $2 node rc=$rc"; exit 1; fi
  if [ -z "$passed" ] || [ -z "$skipped" ]; then cat "$log"; echo "FAIL: client-approval-ui.bh-9901-test: $2 has no test summary"; exit 1; fi
  [ "$passed" -gt 0 ] || { cat "$log"; echo "FAIL: client-approval-ui.bh-9901-test: $2 passed 0 tests"; exit 1; }
  [ "$skipped" = 0 ] || { cat "$log"; echo "FAIL: client-approval-ui.bh-9901-test: $2 skipped $skipped test(s)"; exit 1; }
  TOTAL=$((TOTAL + passed))
}
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  run_node console-ui tests/client-approval.bh-9901.test.js
else
  echo "client-approval-ui.bh-9901-test: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi
run_node mcp test/pr-stage-client-approval.bh-9901.test.mjs
echo "client-approval-ui.bh-9901-test: $TOTAL passed, 0 skipped"
