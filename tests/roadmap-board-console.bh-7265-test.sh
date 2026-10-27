#!/bin/bash
# tests/roadmap-board-console.bh-7265-test.sh — the roadmap board console half
# (BH-7243.2, BH-7265).
#
# The behaviour is proved by node --test in console-ui/tests/ (the App-mounted
# board, the api calls and the coord write fragment) and in worker/jobs/test/
# (the routes and their EXPLAIN plans). This file names the new sources by
# path for the impact lane and the orphan ratchet, and checks:
#   1. every new source exists
#   2. Roadmap.js still mounts RoadmapBoardView for ?view=board, the list view
#      links to the board, and the fragment has exactly the 4 write rows
#   3. the node suites, run when the console-ui dependencies are installed
# Run from anywhere: tests/roadmap-board-console.bh-7265-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/7243-roadmap-board.js"
API="$DIR/console-ui/src/lib/roadmap-api/board.js"
VIEW="$DIR/console-ui/src/screens/roadmap/board-view.js"
LIST="$DIR/console-ui/src/screens/roadmap/list-view.js"
SCREEN="$DIR/console-ui/src/screens/Roadmap.js"
ROUTE="$DIR/worker/jobs/src/routes/roadmap-board.js"
FIXTURE="$DIR/worker/jobs/test/fixtures/roadmap-board.bh-7243.json"

for f in "$FRAG" "$API" "$VIEW" "$SCREEN" "$ROUTE" "$FIXTURE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the wiring -----------------------------------------------------------
grep -q '<${RoadmapBoardView} project=${project} />' "$SCREEN" && ok || bad "Roadmap.js must mount RoadmapBoardView for ?view=board"
grep -q '?view=board`} class="btn btn--sm">BOARD<//>' "$LIST" && ok || bad "the list view must link to the board"
grep -q "path: 'roadmap/links', body: \['idea_id', 'project', 'issue'\]" "$FRAG" && ok || bad "fragment links row"
grep -q "path: 'roadmap/links/remove', body: \['idea_id', 'project', 'issue'\]" "$FRAG" && ok || bad "fragment links/remove row"
grep -q "path: 'roadmap/decisions', body: \['project', 'kind', 'title', 'body'\]" "$FRAG" && ok || bad "fragment decisions row"
grep -q "path: 'roadmap/decisions/decide', body: \['id', 'project', 'status', 'expected_status'\]" "$FRAG" && ok || bad "fragment decide row"
[ "$(grep -c "path: '" "$FRAG")" = 4 ] && ok || bad "the fragment must hold exactly 4 rows"
if grep -nE 'window\.(confirm|alert|prompt)|(^|[^.a-zA-Z_])(alert|prompt)\(' "$VIEW"; then bad "board-view.js calls a native dialog"; else ok; fi
if grep -nE '#[0-9a-fA-F]{3,8}\b' "$VIEW"; then bad "board-view.js carries a hex colour"; else ok; fi

# --- 3: the node suites, driven ----------------------------------------------
command -v node >/dev/null 2>&1 || { echo "roadmap-board-console: node suites SKIPPED — node is not installed on this box"; echo "roadmap-board-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "roadmap-board-console: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/roadmap-board.bh-7243.test.js tests/roadmap-seams.bh-7243.test.js tests/roadmap.bh-7243.test.js 2>&1); then ok
else bad "console-ui roadmap board suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "roadmap-board-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
