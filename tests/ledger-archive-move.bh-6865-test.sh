#!/bin/bash
# tests/ledger-archive-move.bh-6865-test.sh — BH-6865 (BH-6780.2): the
# ledgers.archive retention rule, the per-kind audit map and the sticky wait row.
#
# The behaviour is proved by node --test. This file names every new source by
# path, so the impact lane and the orphan ratchet can see them, and:
#   1. every new source and suite exists;
#   2. the worker suite (worker/jobs/test/ledger-archive-move.bh-6865.test.js)
#      passes with 0 skipped. It drives the real worker.fetch on node:sqlite and
#      makes no vendor call.
# Run from anywhere: tests/ledger-archive-move.bh-6865-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$DIR/worker/jobs/src/lib/ledger-kind-class.js" \
         "$DIR/worker/jobs/src/routes/retention.d/bh-6865-ledgers-archive.js" \
         "$DIR/worker/jobs/schema.d/202611240347-bh-6865-ledger-archive-knobs.sql" \
         "$DIR/worker/jobs/test/ledger-archive-move.bh-6865.test.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "ledger-archive-move.bh-6865: FAIL — node is not installed on this box"; exit 1; }
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }

# A skipped test gates nothing (the worker-jobs skip guard in harness-ci.yml).
skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }

OUT=$(cd "$DIR/worker/jobs" && node --test test/ledger-archive-move.bh-6865.test.js 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok
else bad "the worker ledger-archive-move suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi

echo "ledger-archive-move.bh-6865: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
