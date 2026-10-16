#!/bin/bash
# tests/archive-readers.bh-6779-test.sh — the history readers read the
# archive store too (BH-6779, slice C0).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# worker/jobs/test/archive-readers.bh-6779.test.js: the helper's decision rule
# and merges (H1-H8), the reader inventory (R1), and the three ported routes
# through the real worker.fetch (R2, R3, R4, R6). This file is what the impact
# lane and the orphan ratchet can SEE: it names the new helper and the three
# routes by path, checks the inventory fragment parses, and runs the node suite.
# Run from anywhere: tests/archive-readers.bh-6779-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HELPER="$DIR/worker/jobs/src/lib/archive-read.js"
FRAGMENT="$DIR/worker/jobs/test/archive-readers.d/bh-6779.json"
NODE_SUITE="$DIR/worker/jobs/test/archive-readers.bh-6779.test.js"
for f in "$HELPER" "$FRAGMENT" "$NODE_SUITE" \
         "$DIR/worker/jobs/src/routes/cost-breakdown.js" \
         "$DIR/worker/jobs/src/routes/model-watch.js" \
         "$DIR/worker/jobs/src/routes/job-detail.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "archive-readers: SKIPPED — node is not installed on this box"; exit 0; }

# The worker imports three composed catalogs that are never committed.
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

# The helper loads and exports its four functions.
OUT=$(node --input-type=module -e "
const m = await import('$HELPER');
console.log(['readHistory', 'mergeRows', 'mergeAggregate', 'mergeGroups'].filter((f) => typeof m[f] !== 'function').join(',') || 'all');
" 2>&1)
[ "$OUT" = "all" ] && ok || bad "archive-read.js exports: missing $OUT"

# The fragment is one JSON object with a readers array.
N=$(node -e "const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')); console.log(Array.isArray(d.readers) ? d.readers.length : -1)" "$FRAGMENT" 2>&1)
[ "${N:-0}" -gt 0 ] 2>/dev/null && ok || bad "inventory fragment has no readers array: $N"

# The cost-breakdown route passes the sql-command-injection iron law as a whole
# file (every line fed as an added line), not only on the lines a diff touches.
# The merge conductor refused e90b196c on two hits in this file.
ROUTE="$DIR/worker/jobs/src/routes/cost-breakdown.js"
DIFF="$T/cost-breakdown-whole.diff"
{ printf -- '--- /dev/null\n+++ b/worker/jobs/src/routes/cost-breakdown.js\n@@ -0,0 +1,%d @@\n' "$(wc -l <"$ROUTE")"
  sed 's/^/+/' "$ROUTE"; } >"$DIFF"
CHK=$("$DIR/bin/checks-run.sh" "$DIFF" 2>&1); CRC=$?
if [ "$CRC" -eq 0 ]; then ok; else bad "checks-run on the whole cost-breakdown.js rc=$CRC"; head -10 <<<"$CHK"; fi

# The node suite, for real.
LOG="$T/node-suite.log"
(cd "$DIR/worker/jobs" && node --test test/archive-readers.bh-6779.test.js) >"$LOG" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "node suite rc=$RC"; grep -E '^not ok|error:' "$LOG" | head -20; fi

echo "archive-readers.bh-6779: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
