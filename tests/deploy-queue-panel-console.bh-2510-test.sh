#!/bin/bash
# tests/deploy-queue-panel-console.bh-2510-test.sh — the DEPLOY QUEUE table and
# its audited RELEASE on /p/<project> (BH-2510; slice BH-3152).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by two node suites:
# worker/jobs/test/deploy-queue-actions.bh-2510.test.js (the route, against the
# SQL that ships) and console-ui/tests/deploy-queue-panel.bh-2510.test.js (the
# lib, the view and the real ProjectScreen mount). What this file adds is the
# part the impact lane and the orphan ratchet can SEE: it names the three
# sources by path, holds the screen to the console rules (shared SortableTable,
# the in-app useConfirm, no native dialog), and runs both node suites.
#
#   1. the three sources exist.
#   2. DeployQueuePanel.js sorts through SortableTable, confirms through
#      useConfirm, and neither it nor its lib calls confirm/alert/prompt.
#   3. on the ticket's own branch, the diff leaves queue.js, deploy-train.sh and
#      the build-queue / merge-train files alone (the slice's scope).
#   4. both node suites, run for real when their runtimes are there.
# Run from anywhere: tests/deploy-queue-panel-console.bh-2510-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/deploy-queue-panel.js"
SCREEN="$DIR/console-ui/src/screens/DeployQueuePanel.js"
ROUTE="$DIR/worker/jobs/src/routes/deploy-queue-actions.js"

# --- 1: the sources -----------------------------------------------------------
for f in "$LIB" "$SCREEN" "$ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen's shape ----------------------------------------------------
# A missing file makes every grep below fail, never pass (D3).
grep -q "from '../ui/SortableTable.js'" "$SCREEN" 2>/dev/null && ok || bad "DeployQueuePanel.js must use the shared SortableTable"
grep -q '<\${SortableTable}' "$SCREEN" 2>/dev/null && ok || bad "DeployQueuePanel.js must render its table through SortableTable"
grep -q "from '../ui/Modal.js'" "$SCREEN" 2>/dev/null && ok || bad "DeployQueuePanel.js must import the in-app modal"
grep -q "useConfirm()" "$SCREEN" 2>/dev/null && ok || bad "DeployQueuePanel.js must confirm RELEASE through useConfirm"
grep -q "from '../lib/deploy-queue-panel.js'" "$SCREEN" 2>/dev/null && ok || bad "DeployQueuePanel.js must read its lib"
grep -q '"/api/deploy-queue/action"' "$ROUTE" 2>/dev/null && ok || bad "deploy-queue-actions.js must route POST /api/deploy-queue/action"
if [ -f "$SCREEN" ] && [ -f "$LIB" ]; then
  CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
  # A bare or window. call. useConfirm( and confirm({ (the hook's own function)
  # are not natives: the preceding character rules them out.
  if grep -qE '(^|[^A-Za-z0-9_.])(confirm|alert|prompt)[[:space:]]*\([^{]|window\.(confirm|alert|prompt)[[:space:]]*\(' <<<"$CODE"; then
    bad "a native dialog in the DEPLOY QUEUE screen or its lib"
  else
    ok
  fi
fi

# --- 3: the slice's scope, on its own branch only ------------------------------
# The files the BH-3152 commits on this branch changed (the branch also carries
# the BH-3150 contract commit, which created the stubs). After merge a later
# ticket may touch these files on purpose, so the check runs only here.
BR=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$BR" = "ticket/bh-3152" ] && git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  TOUCHED=$(git -C "$DIR" log --format= --name-only --grep='BH-3152' origin/main..HEAD 2>/dev/null | grep -E '^(worker/jobs/src/routes/(queue|queue-actions)\.js|bin/deploy-train\.sh|console-ui/src/screens/(BuildQueuePanel|MergeTrainsPanel)\.js)$' || true)
  [ -z "$TOUCHED" ] && ok || bad "BH-3152 touched files outside its scope: $TOUCHED"
fi

# --- 4: the node suites ---------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "deploy-queue-panel-console: node suites SKIPPED — node is not installed on this box"
  echo "deploy-queue-panel-console: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

if [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "deploy-queue-panel-console: worker suite SKIPPED — node < 22 has no node:sqlite"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
else
  OUT=$(cd "$DIR/worker/jobs" && node --test test/deploy-queue-actions.bh-2510.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "worker suite rc=$RC"; printf '%s\n' "$OUT" | grep -E '^not ok|error:' | head -20; fi
fi

if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "deploy-queue-panel-console: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  OUT=$(cd "$DIR/console-ui" && node --test tests/deploy-queue-panel.bh-2510.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "console suite rc=$RC"; printf '%s\n' "$OUT" | grep -E '^not ok|error:' | head -20; fi
fi

echo "deploy-queue-panel-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
