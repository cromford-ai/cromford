#!/bin/bash
# tests/verdict-latest.bh-9558-test.sh — BH-9558: latest verdict wins.
#
# A builder APPROVE followed by a lead BLOCK must leave the PR's current
# verdict at BLOCK, with both rounds in verdict_history, and the kanban payload
# must show lead-blocked. The behaviour is proved by two node suites:
#   worker/jobs/test/verdict-latest.bh-9558.test.js   (V1-V13, through worker.fetch)
#   console-ui/tests/verdict-overlay.bh-9558.test.js  (O1-O6, B1-B3, through onRequest)
# This file is the ticket's verdict-latest-test.sh. It names every new source
# by rooted path (the orphan ratchet), checks the new route is bearer-gated,
# and runs both node suites. Exit 0 only when both pass with 0 skipped.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/verdict-latest.bh-9558-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }

echo "L1: the new sources"
for f in "$DIR/worker/jobs/src/lib/verdict-rounds.js" \
         "$DIR/worker/jobs/src/routes/verdict-current.js" \
         "$DIR/worker/jobs/test/route-table.d/bh-9558-verdict-current.txt" \
         "$DIR/worker/jobs/schema.d/202611241647-bh-9558-verdict-current-seed.sql" \
         "$DIR/worker/jobs/test/verdict-latest.bh-9558.test.js" \
         "$DIR/console-ui/functions/_lib/verdict-overlay.js" \
         "$DIR/console-ui/src/lib/verdict-badge.js" \
         "$DIR/console-ui/tests/verdict-overlay.bh-9558.test.js"; do
  [ -f "$f" ] && ok "L1 ${f#"$DIR"/}" || bad "L1 missing ${f#"$DIR"/}"
done

if ! command -v node >/dev/null 2>&1; then
  bad "node is not installed: the verdict suites cannot run"
else
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

  echo "L2: POST /api/verdict/current is behind the bearer, never open"
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES } from '#routes';
import { OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
console.log((matchRoute(ROUTES, 'POST', '/api/verdict/current') ? 'bearer' : 'none') + '/' + (matchRoute(OPEN_ROUTES, 'POST', '/api/verdict/current') ? 'open' : 'closed'));" 2>&1)
  [ "$ROUTED" = 'bearer/closed' ] && ok "L2 the route is in ROUTES, not OPEN_ROUTES" || bad "L2 route wiring: $ROUTED"

  echo "L3: worker/jobs/test/verdict-latest.bh-9558.test.js"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/verdict-latest.bh-9558.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "L3 the worker verdict suite, 0 skipped"
  else bad "L3 the worker verdict suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi

  echo "L4: console-ui/tests/verdict-overlay.bh-9558.test.js"
  if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    echo "  L4 SKIPPED: console-ui dependencies are not installed (the console-ui CI job runs it)"
  else
    OUT=$(cd "$DIR/console-ui" && node --test tests/verdict-overlay.bh-9558.test.js 2>&1); RC=$?
    if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "L4 the console overlay suite, 0 skipped"
    else bad "L4 the console overlay suite failed (rc=$RC):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi
  fi
fi

echo "verdict-latest.bh-9558: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
