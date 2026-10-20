#!/bin/bash
# tests/roadmap-wave-file-console.bh-7243-test.sh — the wave file console half
# (BH-7243.4, BH-7267).
#
# The behaviour is proved by node --test in console-ui/tests/ (the App-mounted
# wave bar, the api calls and the coord write fragment). This file names the
# new sources by path for the impact lane and the orphan ratchet, and checks:
#   1. every new source exists
#   2. the wave screen mounts WaveActions and the fragment has exactly the
#      approve and reject rows
#   3. the node suites, run when the console-ui dependencies are installed
# Run from anywhere: tests/roadmap-wave-file-console.bh-7243-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/7243-roadmap-wave-file.js"
API="$DIR/console-ui/src/lib/roadmap-api/wave-file.js"
BAR="$DIR/console-ui/src/screens/roadmap/wave-actions.js"
SCREEN="$DIR/console-ui/src/screens/Roadmap.js"

for f in "$FRAG" "$API" "$BAR" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the wiring -----------------------------------------------------------
grep -q '<${WaveActions} project=${project} wave=${{ id }} />' "$SCREEN" && ok || bad "Roadmap.js must mount WaveActions on the wave screen"
grep -q "path: 'roadmap/waves/approve', body: \['id', 'project', 'expected_status'\]" "$FRAG" && ok || bad "fragment approve row"
grep -q "path: 'roadmap/waves/reject', body: \['id', 'project', 'reason'\]" "$FRAG" && ok || bad "fragment reject row"
[ "$(grep -c "path: '" "$FRAG")" = 2 ] && ok || bad "the fragment must hold exactly 2 rows"
if grep -nE 'window\.(confirm|alert|prompt)|(^|[^.a-zA-Z_])(confirm|alert|prompt)\(' "$BAR"; then bad "wave-actions.js calls a native dialog"; else ok; fi

# --- 3: the node suites, driven ----------------------------------------------
command -v node >/dev/null 2>&1 || { echo "roadmap-wave-file-console: node suites SKIPPED — node is not installed on this box"; echo "roadmap-wave-file-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "roadmap-wave-file-console: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/roadmap-wave-file.bh-7243.test.js tests/roadmap-seams.bh-7243.test.js tests/coord-writes-roadmap.bh-7243.test.js 2>&1); then ok
else bad "console-ui wave file suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "roadmap-wave-file-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
