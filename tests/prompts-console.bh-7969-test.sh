#!/bin/bash
# tests/prompts-console.bh-7969-test.sh — the console half of the prompts
# contract (BH-7969, BH-7940.0): the /api/prompts proxy and the UI history
# seam, which BH-7940.4 (BH-7972) fills.
#
# The proxy's behaviour is proved by node --test in
# console-ui/tests/prompts-proxy.bh-7969.test.js. This file names both new
# sources by path so the impact lane and the orphan ratchet can see them, and:
#   1. both files exist;
#   2. PromptHistoryActions.js exports both seam names as functions (their
#      behaviour is console-ui/tests/prompt-history.bh-7972.test.js);
#   3. the node suite passes (it needs no console-ui dependencies).
# Run from anywhere: tests/prompts-console.bh-7969-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PROXY="$DIR/console-ui/functions/api/prompts/[[path]].js"
ACTIONS="$DIR/console-ui/src/ui/PromptHistoryActions.js"

for f in "$PROXY" "$ACTIONS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "prompts-console: FAIL — node is not installed on this box"; exit 1; }

# --- 2: the seam exports ---------------------------------------------------
# A text check: importing the module needs preact, and this suite runs without
# console-ui dependencies.
for name in PromptVersionsSheet UseLevelAboveButton; do
  grep -Eq "^export function $name\(" "$ACTIONS" && ok || bad "PromptHistoryActions.js does not export function $name"
done

# --- 3: the proxy node suite ------------------------------------------------
if NOUT=$(cd "$DIR/console-ui" && node --test tests/prompts-proxy.bh-7969.test.js 2>&1); then ok
else bad "console-ui/tests/prompts-proxy.bh-7969.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "prompts-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
