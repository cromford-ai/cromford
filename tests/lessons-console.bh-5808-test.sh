#!/bin/bash
# tests/lessons-console.bh-5808-test.sh — the LESSONS section
# on the Mission Control /lead-reviews screen (BH-5808).
#
# WHY A SHELL SUITE AS WELL. The section is proved by node --test in
# console-ui/tests/lessons.bh-5808.test.js (reached through the
# console-ui job). This file is the part the impact lane and the orphan ratchet
# can SEE: it names console-ui/src/screens/Lessons.js by path and holds
# it to the rules a reviewer would otherwise check by eye
# (the lead-reviews-console.bh-4957 pattern).
#
#   1. Lessons.js exists, renders its tables through the shared
#      SortableTable, and never calls a native dialog.
#   2. LeadReviews.js imports LessonsSection and renders it.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/lessons-console.bh-5808-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Lessons.js"
HOST="$DIR/console-ui/src/screens/LeadReviews.js"
NODE_SUITE="$DIR/console-ui/tests/lessons.bh-5808.test.js"

for f in "$SCREEN" "$HOST" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the section's own rules ----------------------------------------------
grep -q "import { SortableTable } from '../ui/SortableTable.js'" "$SCREEN" && ok \
  || bad "Lessons.js must render its tables through the shared SortableTable"
[ "$(grep -c '<\${SortableTable}' "$SCREEN")" -ge 2 ] && ok \
  || bad "Lessons.js must render both tables (categories, lessons) as SortableTable"
grep -nE '(window\.)?(confirm|alert|prompt)\(' "$SCREEN" > "$T/dialogs" \
  && bad "Lessons.js calls a native dialog: $(cat "$T/dialogs")" || ok

# --- 2: wired into the /lead-reviews screen ----------------------------------
grep -q "import { LessonsSection } from './Lessons.js'" "$HOST" && ok \
  || bad "LeadReviews.js must import LessonsSection"
grep -q '<\${LessonsSection}' "$HOST" && ok || bad "LeadReviews.js must render LessonsSection"

# --- 3: the node suite, driven -----------------------------------------------
command -v node >/dev/null 2>&1 || { echo "lessons-console: node suite SKIPPED — node is not installed on this box"; echo "lessons-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "lessons-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/lessons.bh-5808.test.js 2>&1); then ok
  else bad "console-ui/tests/lessons.bh-5808.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "lessons-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
