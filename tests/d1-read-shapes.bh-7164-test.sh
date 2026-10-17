#!/bin/bash
# tests/d1-read-shapes.bh-7164-test.sh — BH-7164: three harness-jobs read
# shapes over 5,000 rows a call (the progress cost windows and the two
# /api/artifacts variants).
#
# The behaviour is proved by node --test in
# worker/jobs/test/d1-read-shapes.bh-7164.test.js (EXPLAIN QUERY PLAN through
# the real routes on a D1 seeded at live volume). This file names the new
# sources by path, so the impact lane and the orphan ratchet can see them, and
# runs that node suite for real.
# Run from anywhere: tests/d1-read-shapes.bh-7164-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/worker/jobs/src/lib/cost-hourly.js"
ROUTE="$DIR/worker/jobs/src/routes/progress.js"
FRAG="$DIR/worker/jobs/schema.d/202610170247-bh-7164-d1-read-shapes.sql"
SUITE="$DIR/worker/jobs/test/d1-read-shapes.bh-7164.test.js"
for f in "$LIB" "$ROUTE" "$FRAG" "$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
grep -q 'from "../lib/cost-hourly.js"' "$ROUTE" && ok || bad "progress.js does not import lib/cost-hourly.js"

if ! command -v node >/dev/null 2>&1; then
  echo "d1-read-shapes: node suite SKIPPED — node is not installed on this box"
else
  # core.js and llm-sites.js import these generated catalogs statically.
  [ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json"
  "$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null 2>&1 || bad "could not compose catalog/llm-sites.json"
  "$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null 2>&1 || bad "could not compose catalog/context-budgets.json"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/d1-read-shapes.bh-7164.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && grep -q '^# pass [1-9]' <<<"$OUT" && grep -q '^# skipped 0' <<<"$OUT"; then ok
  else bad "node suite rc=$RC"; grep -E '^not ok|^# (pass|fail|skipped)' <<<"$OUT"; fi
fi

echo "d1-read-shapes.bh-7164: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
