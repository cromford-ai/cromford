#!/bin/bash
# tests/archive-readers.bh-7035-test.sh — the wide history readers that C0 of
# #6779 left pending read the archive store too (BH-7035, slice C0).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# worker/jobs/test/archive-readers.bh-7035.test.js: archiveReach and the
# `union` merge (A1-A3), the outcome-gap HAVING and candidate filter (O1-O3),
# and the four ported readers through the real worker.fetch (R2, R3, R4, R6).
# This file is what the impact lane and the orphan ratchet can SEE: it names
# every touched source by path, checks the inventory fragment parses, and runs
# the node suite and the C0 suite whose inventory (R1) this ticket changes.
# Run from anywhere: tests/archive-readers.bh-7035-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HELPER="$DIR/worker/jobs/src/lib/archive-read.js"
FRAGMENT="$DIR/worker/jobs/test/archive-readers.d/bh-7035.json"
NODE_SUITE="$DIR/worker/jobs/test/archive-readers.bh-7035.test.js"
for f in "$HELPER" "$FRAGMENT" "$NODE_SUITE" \
         "$DIR/worker/jobs/src/routes/lane-spend.js" \
         "$DIR/worker/jobs/src/lib/daily-digest/core-sections.js" \
         "$DIR/worker/jobs/src/routes/daily-digest.js" \
         "$DIR/worker/jobs/src/routes/model-routes.js" \
         "$DIR/worker/jobs/src/lib/outcome-gap.js" \
         "$DIR/worker/jobs/src/routes/outcome-gap.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "archive-readers.bh-7035: SKIPPED — node is not installed on this box"; exit 0; }

# The worker imports three composed catalogs that are never committed.
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

# The helper exports the reach check and the state fold.
OUT=$(node --input-type=module -e "
const m = await import('$HELPER');
console.log(['archiveReach', 'readHistory', 'worstState', 'mergeGroups'].filter((f) => typeof m[f] !== 'function').join(',') || 'all');
" 2>&1)
[ "$OUT" = "all" ] && ok || bad "archive-read.js exports: missing $OUT"

# The fragment is one JSON object whose readers are all wide and ported.
N=$(node -e "const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')); const r = Array.isArray(d.readers) ? d.readers : []; console.log(r.length && r.every((x) => x.class === 'wide' && x.status === 'ported') ? r.length : -1)" "$FRAGMENT" 2>&1)
[ "${N:-0}" -gt 0 ] 2>/dev/null && ok || bad "inventory fragment is not a list of wide ported readers: $N"

# The node suites, for real: this ticket's, and C0's (R1 reads both fragments).
for suite in archive-readers.bh-7035.test.js archive-readers.bh-6779.test.js; do
  LOG="$T/$suite.log"
  (cd "$DIR/worker/jobs" && node --test "test/$suite") >"$LOG" 2>&1
  RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "node suite $suite rc=$RC"; grep -E '^not ok|error:' "$LOG" | head -20; fi
done

echo "archive-readers.bh-7035: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
