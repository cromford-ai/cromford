#!/bin/bash
# tests/box-commands-worker.bh-2518-test.sh — the jobs-worker box-commands
# routes (BH-2659 / BH-2518.1).
#
# WHY A SHELL SUITE AS WELL. The routes are proved by node --test in
# worker/jobs/test/box-commands.bh-2518.test.js, which drives the real
# worker.fetch over real SQLite and the real schema.sql (and CI runs it through
# the worker-jobs npm test step). What this file adds is the part the impact
# lane and the orphan ratchet can SEE: it names the route source by path and
# runs that node suite for real when node is installed.
# Run from anywhere: tests/box-commands-worker.bh-2518-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/box-commands.js"
SUITE="$DIR/worker/jobs/test/box-commands.bh-2518.test.js"
INDEX="$DIR/worker/jobs/src/index.js"

for f in "$ROUTE" "$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-box-commands.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "box-commands has no route-table.d fragment (BH-4607: the fragment IS the registration)"

if ! command -v node >/dev/null 2>&1; then
  echo "box-commands-worker: node suite SKIPPED — node is not installed on this box"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247). Without it the
  # node file fails at import in any fresh checkout.
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
else
  if OUT=$(cd "$DIR/worker/jobs" && node --test test/box-commands.bh-2518.test.js 2>&1); then
    ok
  else
    bad "node --test test/box-commands.bh-2518.test.js failed:"
    printf '%s\n' "$OUT" | grep -E '^not ok|AssertionError|Error|# (pass|fail)' | head -40
  fi
  grep -q '^# skipped 0$' <<<"$OUT" && ok || bad "the node suite skipped a test (node:sqlite missing?)"
fi

echo "box-commands-worker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
