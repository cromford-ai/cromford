#!/bin/bash
# tests/otp-inbox.bh-7732-test.sh — BH-7732: the otp inbox Email Worker
# (worker/otp-inbox) and its jobs route GET /api/otp.
#
# The behaviour is proved by node --test: worker/otp-inbox/test/*.test.js
# (the MIME reader, the code matcher's decision table and the email() handler
# on node:sqlite) and worker/jobs/test/otp.bh-7732.test.js (the route, the
# indexes at volume and the retention rule). What this file adds is the part
# CI's tests/*.sh loop and the orphan ratchet can SEE: it names every new
# source by rooted path, checks the route is in the bearer table (never the
# open one), checks the worker's wrangler config binds the harness-jobs D1,
# and runs both node suites for real.
#   I1 every new source file exists      I2 GET /api/otp is bearer-gated
#   I3 wrangler.jsonc: name, entry, D1 binding to the jobs database id
#   I4 worker/otp-inbox node suites      I5 the jobs otp suite
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/otp-inbox.bh-7732-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "I1: the new sources"
for f in worker/otp-inbox/src/index.js worker/otp-inbox/src/mime.js worker/otp-inbox/src/code.js \
         worker/otp-inbox/wrangler.jsonc worker/otp-inbox/package.json \
         worker/jobs/src/routes/otp.js worker/jobs/test/route-table.d/bh-7732-otp.txt \
         worker/jobs/schema.d/202610211454-bh-7732-otp-messages.sql bin/otp-wait.sh \
         tests/lib/otp-worker.bh-7732.mjs; do
  [ -f "$DIR/$f" ] && ok "I1 $f" || bad "I1 missing $f"
done

echo "I3: the wrangler config"
W="$DIR/worker/otp-inbox/wrangler.jsonc"
JOBS_DB=$(grep -o '"database_id": *"[0-9a-f-]*"' "$DIR/worker/jobs/wrangler.jsonc" | head -1 | grep -o '[0-9a-f-]\{36\}')
if [ -f "$W" ] && command -v node >/dev/null 2>&1; then
  # JSONC: drop // comments that start a line or follow a value, then parse.
  CONF=$(node -e '
const s = require("fs").readFileSync(process.argv[1], "utf8").split("\n").map((l) => l.replace(/^\s*\/\/.*$/, "").replace(/,\s*\/\/.*$/, ",")).join("\n");
const c = JSON.parse(s);
const d = (c.d1_databases || []).find((x) => x.binding === "DB") || {};
console.log([c.name, c.main, d.database_name, d.database_id, c.workers_dev, c.triggers ? "triggers" : "no-triggers"].join(" "));' "$W" 2>&1)
  [ "$CONF" = "harness-otp-inbox src/index.js harness-jobs $JOBS_DB false no-triggers" ] \
    && ok "I3 harness-otp-inbox, src/index.js, DB -> harness-jobs ($JOBS_DB), no workers.dev, no triggers" || bad "I3 config: $CONF (jobs db $JOBS_DB)"
else
  bad "I3 no wrangler.jsonc or no node"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "otp-inbox: node suites SKIPPED — node is not installed on this box"
else
  worker_catalogs "$DIR" || exit 1
  echo "I2: the route table"
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
console.log(matchRoute(ROUTES, 'GET', '/api/otp') ? 'bearer' : 'none', matchRoute(OPEN_ROUTES, 'GET', '/api/otp') ? 'open' : 'closed');" 2>&1)
  [ "$ROUTED" = 'bearer closed' ] && ok "I2 GET /api/otp is in ROUTES, not OPEN_ROUTES" || bad "I2 route wiring: $ROUTED"
  # A skipped test gates nothing, the same rule as the worker-jobs skip guard
  # in harness-ci.yml. The counts carry an `ℹ` prefix under the spec reporter
  # and a `#` under tap.
  skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }
  echo "I4: worker/otp-inbox node suites"
  # This is the CI run of the worker's package.json test script: the cd stands
  # on its own line, which is how tests/harness-ci-worker-jobs.bh-1137-test.sh
  # finds a tests/*.sh runner for worker/otp-inbox (BH-1137, BH-1920).
  OUT=$(
    cd "$DIR/worker/otp-inbox" || exit 1
    node --test test/*.test.js 2>&1
  ); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "I4 worker/otp-inbox/test/*.test.js, 0 skipped"
  else bad "I4 worker/otp-inbox node suites failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|skipped|SKIP|Error|expected|actual' | head -40; fi
  echo "I5: worker/jobs/test/otp.bh-7732.test.js"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/otp.bh-7732.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "I5 worker/jobs/test/otp.bh-7732.test.js, 0 skipped"
  else bad "I5 jobs otp suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|skipped|SKIP|Error|expected|actual' | head -40; fi
fi

echo "otp-inbox.bh-7732: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
