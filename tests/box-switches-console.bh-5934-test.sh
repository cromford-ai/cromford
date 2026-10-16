#!/bin/bash
# tests/box-switches-console.bh-5934-test.sh — BH-5934 item 3: the BOX SWITCHES
# section on the console /flags screen.
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/box-switches.bh-5934.test.js (the console-ui CI job). This
# file is the part the impact lane and the orphan ratchet can SEE (the
# flags-console.bh-4153 pattern):
#   1. console-ui/src/lib/box-switches.js, DRIVEN: only an ON
#      switch.<name>.<box> row is listed, an unreadable body is null.
#   2. Flags.js reads the rows through it.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/box-switches-console.bh-5934-test.sh   (exit 0 = all pass)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$REPO/console-ui/src/lib/box-switches.js"
SCREEN="$REPO/console-ui/src/screens/Flags.js"
for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "box-switches-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { boxSwitchRows } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const s = (key, value) => ({ key, value, actor: 'fly-1', updated_at: '2026-10-16T10:00:00Z' });
const res = { settings: [s('switch.fly-disabled.fly-1', '1'), s('switch.resume-disabled.hub', 'off'),
  s('switch.fly-disabled', '1'), s('switch.a.box.hub', '1'), s('lane.fly-pool.x', '1')] };
eq('rows',     boxSwitchRows(res).map((r) => [r.name, r.box, r.set_by, r.set_at]),
               [['fly-disabled', 'fly-1', 'fly-1', '2026-10-16T10:00:00Z']]);
eq('empty',    boxSwitchRows({ settings: [] }), []);
eq('unread',   [boxSwitchRows(null), boxSwitchRows({}), boxSwitchRows({ settings: 'x' })], [null, null, null]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen reads through it ------------------------------------------
grep -q "from '../lib/box-switches.js'" "$SCREEN" && ok || bad "Flags.js must read the rows through lib/box-switches.js"

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$REPO/console-ui/node_modules/preact-render-to-string" ]; then
  echo "box-switches-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$REPO/console-ui" && node --test tests/box-switches.bh-5934.test.js 2>&1); then ok
  else bad "console-ui/tests/box-switches.bh-5934.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "box-switches-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
