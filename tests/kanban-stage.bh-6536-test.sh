#!/bin/bash
# tests/kanban-stage.bh-6536-test.sh — the kanban's ticket_stage join (BH-6536).
#
# bin/lib/needs-human/step-done.sh writes ledgers(kind=ticket_stage). The
# console's pipeline function joins it onto the board at read time, and the
# Kanban screen shows the reason on the card and the list row. The behaviour is
# proved by node --test in console-ui/tests/kanban-stage.bh-6536.test.js. This
# file names both sources by path so the impact lane and the orphan ratchet can
# see them, and runs that node suite when the console-ui dependencies exist.
# Run from anywhere: tests/kanban-stage.bh-6536-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SRC1="$DIR/console-ui/functions/api/dash/kanban/pipeline.js"
SRC2="$DIR/console-ui/src/screens/Kanban.js"
SUITE="$DIR/console-ui/tests/kanban-stage.bh-6536.test.js"

for f in "$SRC1" "$SRC2" "$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "kanban-stage: SKIPPED — node is not installed on this box"; exit 0; }

if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "kanban-stage: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/kanban-stage.bh-6536.test.js 2>&1); then ok
  else bad "console-ui/tests/kanban-stage.bh-6536.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "kanban-stage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
