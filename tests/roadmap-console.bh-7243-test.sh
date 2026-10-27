#!/bin/bash
# tests/roadmap-console.bh-7243-test.sh — the roadmap contract and tracer
# (BH-7243.0, BH-7263).
#
# The behaviour is proved by node --test in worker/jobs/test/ (the routes,
# retention and EXPLAIN suites) and console-ui/tests/ (the coord write and the
# console seams). This file names the new sources by path for the impact lane
# and the orphan ratchet, and checks the wiring:
#   1. every new source exists
#   2. Roadmap.js, DRIVEN: the 4 screens are exported and the board view is
#      picked only by ?view=board (preact-render-to-string, when installed)
#   3. app.js routes /roadmap* and the jobs fragment lists the 2 routes
#   4. the node suites, run when their dependencies are installed
# Run from anywhere: tests/roadmap-console.bh-7243-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Roadmap.js"
IDEAS_API="$DIR/console-ui/src/lib/roadmap-api/ideas.js"
APP="$DIR/console-ui/src/app.js"
FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/7243-roadmap-ideas.js"
ROUTE="$DIR/worker/jobs/src/routes/roadmap-ideas.js"
ROUTE_FRAG="$DIR/worker/jobs/test/route-table.d/bh-7243-roadmap-ideas.txt"
SCHEMA="$DIR/worker/jobs/schema.d/202610182038-bh-7243-roadmap-ideas.sql"

for f in "$SCREEN" "$IDEAS_API" "$APP" "$FRAG" "$ROUTE" "$ROUTE_FRAG" "$SCHEMA"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "roadmap-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: Roadmap.js, driven ---------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "roadmap-console: render SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
globalThis.window = { location: { pathname: '/roadmap/p', search: '' }, addEventListener() {}, removeEventListener() {} };
const { h } = await import('preact');
const { render } = await import('preact-render-to-string');
const S = await import('$SCREEN');
const say = (name, cond) => console.log((cond ? 'ok ' : 'no ') + name);
for (const n of ['RoadmapIndexScreen', 'RoadmapScreen', 'RoadmapIdeaScreen', 'RoadmapWaveScreen']) say('export ' + n, typeof S[n] === 'function');
const list = render(h(S.RoadmapScreen, { project: 'p' }));
window.location.search = '?view=board';
const board = render(h(S.RoadmapScreen, { project: 'p' }));
say('list by default', /data-testid=\"roadmap-add\"/.test(list) && !/Not built yet/.test(list) && !/BH-7243\.2/.test(list));
say('board on ?view=board', /data-testid=\"roadmap-board-skeleton\"/.test(board) && !/Not built yet/.test(board) && !/data-testid=\"roadmap-add\"/.test(board));
" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok ;;
      no\ *) bad "Roadmap.js: ${line#no }" ;;
      *) [ -n "$line" ] && bad "Roadmap.js: unexpected output: $line" ;;
    esac
  done <<< "$OUT"
fi

# --- 3: the wiring -----------------------------------------------------------
for r in "\['/roadmap', RoadmapIndexScreen\]" "\['/roadmap/:project', RoadmapScreen\]" \
         "\['/roadmap/:project/idea/:id', RoadmapIdeaScreen\]" "\['/roadmap/:project/wave/:id', RoadmapWaveScreen\]"; do
  grep -q "$r" "$APP" && ok || bad "app.js must route $r"
done
[ "$(grep -cvE '^(#|$)' "$ROUTE_FRAG")" = 6 ] && ok || bad "the route fragment must list exactly 6 routes"
grep -qx 'GET /api/roadmap/ideas' "$ROUTE_FRAG" && grep -qx 'POST /api/roadmap/ideas' "$ROUTE_FRAG" && ok || bad "route fragment rows"
# BH-7243.1 (BH-7264): move, edit, summary and the idea detail.
for r in 'POST /api/roadmap/ideas/move' 'POST /api/roadmap/ideas/edit' 'GET /api/roadmap/summary' \
         'GET re:/^\/api\/roadmap\/ideas\/([^/]+)$/'; do
  grep -qxF "$r" "$ROUTE_FRAG" && ok || bad "route fragment row $r"
done

# --- 4: the node suites, driven ----------------------------------------------
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/routes/roadmap-ideas.bh-7243.test.js test/roadmap-retention.bh-7243.test.js test/roadmap-explain.bh-7243.test.js 2>&1); then ok
else bad "worker/jobs roadmap suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "roadmap-console: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/coord-writes-roadmap.bh-7243.test.js tests/roadmap-seams.bh-7243.test.js 2>&1); then ok
else bad "console-ui roadmap suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "roadmap-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
