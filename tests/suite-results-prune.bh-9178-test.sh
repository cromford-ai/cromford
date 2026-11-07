#!/bin/bash
# tests/suite-results-prune.bh-9178-test.sh — BH-9178 (C2 of #9063): the inline
# 30-day prune in PUT /api/suite-results yields to the scheduled 14-day rule
# once that rule deletes (retention.dry_run=0 and retention.suite_results.days
# > 0). It names the route by path (so bin/test-impact.sh selects this suite
# when it changes) and runs the node suite that pins it, through worker.fetch
# on node:sqlite.
#   E1  the route and the node suite exist
#   N1  worker/jobs/test/suite-results-prune.bh-9178.test.js passes (P1-P4)
# No network. Run from anywhere:
#   bash tests/suite-results-prune.bh-9178-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

FILES=(
  "$DIR/worker/jobs/src/routes/suite-results.js"
  "$DIR/worker/jobs/test/suite-results-prune.bh-9178.test.js"
)
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then ok; else bad "E1 missing: ${f#"$DIR"/}"; fi
done

# The worker imports git-ignored renders (catalog/lanes.json and kin); CI's
# worker job renders them before the node suites, so compose them when absent.
[ -f "$DIR/catalog/lanes.json" ] || "$DIR/bin/lanes-build.sh" --write >/dev/null 2>&1
[ -f "$DIR/catalog/llm-sites.json" ] || "$DIR/bin/llm-sites-build.sh" --compose >/dev/null 2>&1
[ -f "$DIR/catalog/context-budgets.json" ] || "$DIR/bin/context-budgets-build.sh" --compose >/dev/null 2>&1

out=$(cd "$DIR/worker/jobs" && node --test test/suite-results-prune.bh-9178.test.js 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "N1 test/suite-results-prune.bh-9178.test.js rc=$rc"; printf '%s\n' "$out" | grep -E '^not ok|^# (pass|fail)|Error|expected|actual' | head -30; fi

echo "suite-results-prune.bh-9178: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
