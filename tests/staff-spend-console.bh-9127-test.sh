#!/bin/bash
# tests/staff-spend-console.bh-9127-test.sh — spend per staff agent on /staff
# and /staff/:agent, Archie's turn rows, and COSTS filtered to one agent
# (/costs?agent=<name>) (BH-9127).
#
# WHY A SHELL SUITE AS WELL. The screens are proved by node --test in
# console-ui/tests/staff-spend.bh-9127.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the two new sources by path, holds the screens to the rules a
# reviewer would otherwise check by eye, and runs the node suite when the
# console-ui dependencies are installed (the cost-breaker-console.bh-2331
# pattern). The lib imports preact, so it is driven only through that suite.
#
#   1. the new sources exist, and Staff.js, Costs.js and lib/staff-activity.js
#      use them (SPEND cell, detail facts, the ?agent= section, the turn row).
#   2. AgentSpend.js sorts through the shared SortableTable, checks the agent
#      name before any request, reads roster and lane spend in parallel, prints
#      money through fmtUsdExact (no toFixed( and no literal $${), and calls no
#      native dialog.
#   3. the node suite, run for real when the dependencies are installed.
# Run from anywhere: tests/staff-spend-console.bh-9127-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/staff-spend.js"
SCREEN="$DIR/console-ui/src/screens/AgentSpend.js"
STAFF="$DIR/console-ui/src/screens/Staff.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"
ACT="$DIR/console-ui/src/lib/staff-activity.js"

for f in "$LIB" "$SCREEN" "$STAFF" "$COSTS" "$ACT"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the wiring -----------------------------------------------------------
grep -q "from '../lib/staff-spend.js'" "$STAFF" && ok || bad "Staff.js must import lib/staff-spend.js"
grep -q "spendCell(r, sources)" "$STAFF" && ok || bad "Staff.js SPEND column must render spendCell"
grep -q "spendFacts(row" "$STAFF" && ok || bad "Staff.js detail facts must render spendFacts"
grep -q "useSearchParam('agent')" "$COSTS" && ok || bad "Costs.js must read ?agent="
grep -q "AgentLaneSpendSection" "$COSTS" && ok || bad "Costs.js must mount AgentLaneSpendSection"
grep -q "e.kind === 'turn'" "$ACT" && ok || bad "lib/staff-activity.js rowOf must handle the turn kind"
grep -q 'costsHref = (agent) => `/costs?agent=${encodeURIComponent(agent)}`' "$LIB" && ok || bad "costsHref must encode the agent into /costs?agent="

# --- 2: the screen's shape ---------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "AgentSpend.js must use the shared SortableTable"
grep -q "Promise.all(\[api.staffRoster(), api.laneSpend()\])" "$SCREEN" && ok || bad "AgentSpend.js must read roster and lane spend in parallel"
grep -q "AGENT_RE = /^\[a-z\]\[a-z0-9-\]{1,39}\$/" "$SCREEN" && ok || bad "AgentSpend.js must check the agent name against AGENT_RE"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if grep -qE '\.toFixed\(|\$\$\{' <<< "$CODE"; then bad "toFixed( or a literal \$\${ in the agent spend sources (use fmtUsdExact)"; else ok; fi
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then bad "a native dialog in the agent spend sources"; else ok; fi

# --- 3: the node suite, driven -----------------------------------------------
command -v node >/dev/null 2>&1 || { echo "staff-spend-console: node suite SKIPPED — node is not installed on this box"; echo "staff-spend-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-spend-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/staff-spend.bh-9127.test.js 2>&1); then ok
  else bad "console-ui/tests/staff-spend.bh-9127.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "staff-spend-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
