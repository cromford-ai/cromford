#!/bin/bash
# tests/suite-ledger-trust.bh-9063-test.sh — BH-9063 (C0): the suite ledger's
# trust knob, red rows and retention rules. It names the new worker sources by
# path (so bin/test-impact.sh selects this suite when one changes) and runs the
# two node suites that pin them, through worker.fetch on node:sqlite.
#   E1  the sources, the seed and the node suites exist
#   N1  worker/jobs/test/suite-results-trust.bh-9063.test.js passes
#   N2  worker/jobs/test/suite-results-retention.bh-9063.test.js passes
# No network. Run from anywhere:
#   bash tests/suite-ledger-trust.bh-9063-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

FILES=(
  "$DIR/worker/jobs/src/lib/suite-trust.js"
  "$DIR/worker/jobs/src/lib/core.d/bh-9063-suite-results-fp.js"
  "$DIR/worker/jobs/src/routes/retention.d/bh-9063-suite-ledger.js"
  "$DIR/worker/jobs/src/routes/suite-results.js"
  "$DIR/worker/jobs/schema.d/202611051404-bh-9063-suite-ledger.sql"
  "$DIR/worker/jobs/test/suite-results-trust.bh-9063.test.js"
  "$DIR/worker/jobs/test/suite-results-retention.bh-9063.test.js"
)
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then ok; else bad "E1 missing: ${f#"$DIR"/}"; fi
done

# The worker imports git-ignored renders (catalog/lanes.json and kin); CI's
# worker job renders them before the node suites, so compose them when absent.
[ -f "$DIR/catalog/lanes.json" ] || "$DIR/bin/lanes-build.sh" --write >/dev/null 2>&1
[ -f "$DIR/catalog/llm-sites.json" ] || "$DIR/bin/llm-sites-build.sh" --compose >/dev/null 2>&1
[ -f "$DIR/catalog/context-budgets.json" ] || "$DIR/bin/context-budgets-build.sh" --compose >/dev/null 2>&1

for n in N1:suite-results-trust N2:suite-results-retention; do
  id=${n%%:*}; t=${n#*:}
  out=$(cd "$DIR/worker/jobs" && node --test "test/$t.bh-9063.test.js" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok; else bad "$id test/$t.bh-9063.test.js rc=$rc"; printf '%s\n' "$out" | grep -E '^not ok|^# (pass|fail)|Error' | head -20; fi
done

echo "suite-ledger-trust: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
