#!/bin/bash
# tests/secret-envelope-apply.bh-7965-test.sh — BH-7965 (BH-7937.2): the hub half
# of the secret envelope in the jobs worker: the pending list, the confirm, the
# sweep and the public key (worker/jobs/src/routes/secret-envelope-apply.js).
#
# The behaviour is proved by node --test in
# worker/jobs/test/secret-envelope-apply.bh-7965.test.js (the real worker.fetch
# on node:sqlite: the hub gate, 409 on a second confirm, the sweep and its
# archive, EXPLAIN at volume). This file names every new source by rooted path
# for CI's tests/*.sh loop and the orphan ratchet, checks the 4 routes are in
# the bearer table (never the open one), and runs the node suite for real.
#   A1 every new source file exists   A2 the 4 routes are bearer-gated
#   A3 the jobs suite, 0 skipped
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/secret-envelope-apply.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "A1: the new sources"
for f in "$DIR/worker/jobs/src/routes/secret-envelope-apply.js" \
         "$DIR/worker/jobs/schema.d/202610251952-bh-7965-envelope-sweep-settings.sql" \
         "$DIR/worker/jobs/test/secret-envelope-apply.bh-7965.test.js" \
         "$DIR/worker/jobs/test/route-table.d/bh-7964-secret-envelope-apply.txt"; do
  [ -s "$f" ] && ok "A1 ${f#"$DIR"/}" || bad "A1 missing ${f#"$DIR"/}"
done

if ! command -v node >/dev/null 2>&1; then
  echo "secret-envelope-apply: node suites SKIPPED — node is not installed on this box"
else
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }
  echo "A2: the route table"
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
const id = crypto.randomUUID();
const q = [['GET', '/api/secrets/envelope'], ['POST', '/api/secrets/envelope/' + id + '/confirm'],
  ['POST', '/api/secrets/envelope/sweep'], ['PUT', '/api/secrets/envelope/public-key'],
  ['GET', '/api/secrets/envelope/' + id + '/confirm']];
console.log(q.map(([m, p]) => (matchRoute(ROUTES, m, p) ? 'bearer' : 'none') + '/' + (matchRoute(OPEN_ROUTES, m, p) ? 'open' : 'closed')).join(' '));" 2>&1)
  [ "$ROUTED" = 'bearer/closed bearer/closed bearer/closed bearer/closed none/closed' ] \
    && ok "A2 the 4 routes are in ROUTES, not OPEN_ROUTES; GET /:id/confirm matches neither" || bad "A2 route wiring: $ROUTED"
  skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }
  echo "A3: worker/jobs/test/secret-envelope-apply.bh-7965.test.js"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/secret-envelope-apply.bh-7965.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "A3 worker/jobs/test/secret-envelope-apply.bh-7965.test.js, 0 skipped"
  else bad "A3 jobs secret-envelope-apply suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|skipped|SKIP|Error|expected|actual' | head -40; fi
fi

echo "secret-envelope-apply.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
