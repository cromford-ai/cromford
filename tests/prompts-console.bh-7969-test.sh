#!/bin/bash
# tests/prompts-console.bh-7969-test.sh — the console half of the prompts
# contract (BH-7969, BH-7940.0): the /api/prompts proxy and the UI placeholder
# seam that BH-7940.4 fills.
#
# The proxy's behaviour is proved by node --test in
# console-ui/tests/prompts-proxy.bh-7969.test.js. This file names both new
# sources by path so the impact lane and the orphan ratchet can see them, and:
#   1. both files exist;
#   2. PromptHistoryActions.js exports the two placeholders, each returning null;
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

# --- 2: the placeholder seam ------------------------------------------------
if node --input-type=module -e "
import { PromptVersionsSheet, UseLevelAboveButton } from '$ACTIONS';
if (PromptVersionsSheet() !== null || UseLevelAboveButton() !== null) process.exit(1);
"; then ok; else bad "PromptHistoryActions.js placeholders do not both return null"; fi

# --- 3: the proxy node suite ------------------------------------------------
if NOUT=$(cd "$DIR/console-ui" && node --test tests/prompts-proxy.bh-7969.test.js 2>&1); then ok
else bad "console-ui/tests/prompts-proxy.bh-7969.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "prompts-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
