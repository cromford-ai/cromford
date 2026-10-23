#!/bin/bash
# tests/secret-envelopes.bh-7964-test.sh — BH-7964 (BH-7937.0): the one-time
# secret envelope routes POST /api/secrets/envelope and
# GET /api/secrets/envelope/:id in the jobs worker.
#
# The behaviour is proved by node --test in
# worker/jobs/test/secret-envelopes.bh-7964.test.js (the real worker.fetch on
# node:sqlite: the gates, read-once, expiry, the TTL row, EXPLAIN at volume).
# What this file adds is the part CI's tests/*.sh loop and the orphan ratchet
# can SEE: it names every new source by rooted path, checks both routes are in
# the bearer table (never the open one), and runs the node suite for real.
#   S1 every new source file exists      S2 both routes are bearer-gated
#   S3 the jobs secret-envelopes suite, 0 skipped
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/secret-envelopes.bh-7964-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "S1: the new sources"
for f in worker/jobs/src/routes/secret-envelopes.js worker/jobs/src/routes/secret-envelope-apply.js \
         worker/jobs/src/routes/ai-accounts.js \
         worker/jobs/test/route-table.d/bh-7964-secret-envelopes.txt \
         worker/jobs/test/route-table.d/bh-7964-secret-envelope-apply.txt \
         worker/jobs/test/route-table.d/bh-7964-ai-accounts.txt \
         worker/jobs/schema.d/202610220411-bh-7964-secret-envelopes.sql \
         worker/jobs/test/secret-envelopes.bh-7964.test.js; do
  [ -f "$DIR/$f" ] && ok "S1 $f" || bad "S1 missing $f"
done

if ! command -v node >/dev/null 2>&1; then
  echo "secret-envelopes: node suites SKIPPED — node is not installed on this box"
else
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }
  echo "S2: the route table"
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
const id = crypto.randomUUID();
const q = [['POST', '/api/secrets/envelope'], ['GET', '/api/secrets/envelope/' + id], ['GET', '/api/secrets/envelope/' + id + '/status']];
console.log(q.map(([m, p]) => (matchRoute(ROUTES, m, p) ? 'bearer' : 'none') + '/' + (matchRoute(OPEN_ROUTES, m, p) ? 'open' : 'closed')).join(' '));" 2>&1)
  [ "$ROUTED" = 'bearer/closed bearer/closed none/closed' ] \
    && ok "S2 POST and GET are in ROUTES, not OPEN_ROUTES; /:id/status matches neither" || bad "S2 route wiring: $ROUTED"
  # A skipped test gates nothing, the same rule as the worker-jobs skip guard
  # in harness-ci.yml.
  skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }
  echo "S3: worker/jobs/test/secret-envelopes.bh-7964.test.js"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/secret-envelopes.bh-7964.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "S3 worker/jobs/test/secret-envelopes.bh-7964.test.js, 0 skipped"
  else bad "S3 jobs secret-envelopes suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|skipped|SKIP|Error|expected|actual' | head -40; fi
fi

echo "secret-envelopes.bh-7964: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
