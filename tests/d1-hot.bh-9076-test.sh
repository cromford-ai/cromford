#!/bin/bash
# tests/d1-hot.bh-9076-test.sh — the D1 hot statements slice (BH-9076, slice 5
# of BH-9067): the sampled statement counter, GET /api/d1/stmt-stats/top, the
# 20 hot statements EXPLAIN suite and the retention coverage of schema.d/.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by four node suites on
# node:sqlite (named in part 3). This file names every new source by path, so
# the impact lane and the orphan ratchet can see them, drives the pure half of
# the counter with node, and runs the node suites.
#
#   1. every new source exists; index.js wraps the handler once
#   2. normalizeSql, sqlHash and sampled, DRIVEN
#   3. the four node suites
# Run from anywhere: tests/d1-hot.bh-9076-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT_DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$ROOT_DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W="$ROOT_DIR/worker/jobs"
LIB="$W/src/lib/stmt-stats.js"
ROUTE="$W/src/routes/d1-stmt-stats.js"
INDEX="$W/src/index.js"
ARCHIVE_SPECS="$W/src/lib/archive-tables.bh-9076.js"
RULE_STATS="$W/src/routes/retention.d/bh-9076-d1-stmt-stats.js"
RULE_DELETE="$W/src/routes/retention.d/bh-9076-ops-delete.js"
RULE_ARCHIVE="$W/src/routes/retention.d/bh-9076-history-archive.js"
SCHEMA_STATS="$W/schema.d/202611070338-bh-9076-d1-stmt-stats.sql"
SCHEMA_HOT="$W/schema.d/202611070339-bh-9076-hot-indexes.sql"
SCHEMA_RET="$W/schema.d/202611070340-bh-9076-retention-indexes.sql"
SCHEMA_NORET="$W/schema.d/202611070341-bh-9076-no-retention.sql"
TABLE="$W/test/route-table.d/bh-9076-d1-stmt-stats.txt"
FIXTURE="$W/test/fixtures/hot-statements.bh-9076.json"
SCAN_LIB="$W/test/lib/hot-scan.bh-9076.js"

for f in "$LIB" "$ROUTE" "$INDEX" "$ARCHIVE_SPECS" "$RULE_STATS" "$RULE_DELETE" "$RULE_ARCHIVE" \
         "$SCHEMA_STATS" "$SCHEMA_HOT" "$SCHEMA_RET" "$SCHEMA_NORET" "$TABLE" "$FIXTURE" "$SCAN_LIB"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
grep -q '^export default withHarnessSentry(withStmtStats({' "$INDEX" && ok || bad "index.js does not wrap the handler with withStmtStats"
grep -q 'CREATE INDEX IF NOT EXISTS idx_d1_stmt_stats_hour_calls ON d1_stmt_stats(hour, calls)' "$SCHEMA_STATS" && ok || bad "no hour/calls index in the stats fragment"

command -v node >/dev/null 2>&1 || { echo "d1-hot: SKIPPED the node half — node is not installed on this box"; echo "d1-hot: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 2: the pure half, driven -----------------------------------------------
OUT=$(node --input-type=module -e "
import { normalizeSql, sqlHash, sampled } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('normalize', normalizeSql(\"SELECT a FROM t WHERE b = 'x' AND c IN (1, 2) LIMIT 5\"), 'SELECT a FROM t WHERE b = ? AND c IN (?) LIMIT ?');
eq('hash-shape', /^[0-9a-f]{16}\$/.test(sqlHash('SELECT 1')), true);
eq('hash-fold', sqlHash(normalizeSql('SELECT * FROM jobs WHERE id = 5')), sqlHash(normalizeSql('SELECT * FROM jobs WHERE id = 9')));
eq('hash-differs', sqlHash('SELECT * FROM jobs') === sqlHash('SELECT * FROM wakes'), false);
eq('sample-100', sampled(100, 0.999), true);
eq('sample-0', sampled(0, 0), false);
eq('sample-edge', sampled(1, 0.01), false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in ok\ *) ok ;; *) bad "pure: $line" ;; esac
done <<<"$OUT"

# --- 3: the node suites -----------------------------------------------------
for s in stmt-stats.bh-9076 hot-statements-explain.bh-9076 d1-retention-coverage.bh-9076 retention-rules-explain.bh-9076; do
  if (cd "$W" && node --test "test/$s.test.js" >/dev/null 2>&1); then ok; else bad "worker/jobs/test/$s.test.js is red"; fi
done

echo "d1-hot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
