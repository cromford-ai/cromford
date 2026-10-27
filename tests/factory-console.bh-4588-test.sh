#!/bin/bash
# tests/factory-console.bh-4588-test.sh — the console FACTORY screen on
# /factory (BH-4588).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/factory.bh-4588.test.js (reached through the console-ui
# job). This file adds the part the impact lane and the orphan ratchet can SEE:
# it names the two new sources by path, holds the screen to the rules a
# reviewer would otherwise check by eye, and runs the node suite.
#
#   1. Factory.js and lib/factory-api.js exist, and app.js mounts /factory.
#   2. Factory.js sorts through the shared SortableTable, reads through
#      lib/factory-api.js only, and never calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/factory-console.bh-4588-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Factory.js"
LIB="$DIR/console-ui/src/lib/factory-api.js"
APP="$DIR/console-ui/src/app.js"

for f in "$SCREEN" "$LIB" "$APP"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1-2: the screen's shape ------------------------------------------------
grep -q "\['/factory', FactoryScreen\]" "$APP" && ok || bad "app.js must mount /factory in ROUTES"
grep -q "p === '/factory'" "$APP" && ok || bad "app.js must light the STAFF tab on /factory"
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Factory.js must use the shared SortableTable"
grep -q "from '../lib/factory-api.js'" "$SCREEN" && ok || bad "Factory.js must read through lib/factory-api.js"
grep -q "/api/coord/archie/factory-report" "$LIB" && ok || bad "factory-api.js must read /api/coord/archie/factory-report"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the FACTORY screen"
else
  ok
fi
if grep -q "fetch(" <<< "$(grep -hvE '^[[:space:]]*//' "$SCREEN")"; then
  bad "Factory.js must not fetch on its own: one read, through factory-api.js"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
# Without node or the console deps it says so and skips (the console-ui CI job
# runs it).
if ! command -v node >/dev/null 2>&1; then
  echo "factory-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "factory-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/factory.bh-4588.test.js 2>&1); then ok
  else bad "console-ui/tests/factory.bh-4588.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "factory-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
