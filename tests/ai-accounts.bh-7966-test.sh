#!/bin/bash
# tests/ai-accounts.bh-7966-test.sh — BH-7966 (BH-7937.2): the AI account rows
# (worker/jobs/src/routes/ai-accounts.js), the console seal helper, the add
# sheet, the fleet table and the per-project choice.
#
# The behaviour is proved by node --test: worker/jobs/test/ai-accounts.bh-7966.test.js
# and ai-accounts-explain.bh-7966.test.js here, and the console-ui tests
# (envelope, ai-account-sheet, fleet-accounts, coord-writes-ai-accounts) in the
# console-ui job. What this file adds is the part CI's tests/*.sh loop and the
# orphan ratchet can SEE: it names every new source by rooted path, checks the
# four routes are bearer-gated (never open), drives the pure console libs, and
# runs the worker suites for real.
#   A1 every new source file exists     A2 the four routes are in ROUTES, not OPEN_ROUTES
#   A3 the console libs, driven         A4 the stylesheet is tokens only
#   A5 the worker suites, 0 skipped
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ai-accounts.bh-7966-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "A1: the new sources"
for f in worker/jobs/src/routes/ai-accounts.js \
         worker/jobs/schema.d/202610232044-bh-7966-ai-accounts.sql \
         worker/jobs/test/route-table.d/bh-7964-ai-accounts.txt \
         worker/jobs/test/archive-readers.d/bh-7966.json \
         worker/jobs/test/ai-accounts.bh-7966.test.js \
         worker/jobs/test/ai-accounts-explain.bh-7966.test.js \
         console-ui/functions/_lib/coord-writes.d/7966-ai-accounts.js \
         console-ui/src/lib/envelope.js \
         console-ui/src/lib/ai-accounts.js \
         console-ui/src/screens/AiAccountSheet.js \
         console-ui/src/screens/FleetAccounts.js \
         console-ui/src/ui/AiAccountChoiceSheet.js \
         console-ui/src/ai-accounts.css \
         console-ui/tests/envelope.bh-7966.test.js \
         console-ui/tests/ai-account-sheet.bh-7966.test.js \
         console-ui/tests/fleet-accounts.bh-7966.test.js \
         console-ui/tests/coord-writes-ai-accounts.bh-7966.test.js \
         console-ui/tests/drive/ai-accounts.bh-7966-drive.mjs; do
  [ -f "$DIR/$f" ] && ok "A1 $f" || bad "A1 missing $f"
done

echo "A4: console-ui/src/ai-accounts.css is tokens only, and main.js imports it"
CSS="$DIR/console-ui/src/ai-accounts.css"
if grep -qE '#[0-9a-fA-F]{3,8}\b' "$CSS"; then bad "A4 a hex colour in ai-accounts.css"; else ok "A4 no hex colour"; fi
grep -q "^import './ai-accounts.css';" "$DIR/console-ui/src/main.js" && ok "A4 main.js imports it" || bad "A4 main.js does not import ai-accounts.css"

if ! command -v node >/dev/null 2>&1; then
  echo "ai-accounts: node suites SKIPPED — node is not installed on this box"
else
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }
  echo "A2: the route table"
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
const id = crypto.randomUUID();
const q = [['GET', '/api/ai-accounts'], ['POST', '/api/ai-accounts'], ['POST', '/api/ai-accounts/' + id + '/revoke'], ['GET', '/api/secrets/envelope/' + id + '/status']];
console.log(q.map(([m, p]) => (matchRoute(ROUTES, m, p) ? 'bearer' : 'none') + '/' + (matchRoute(OPEN_ROUTES, m, p) ? 'open' : 'closed')).join(' '));" 2>&1)
  [ "$ROUTED" = 'bearer/closed bearer/closed bearer/closed bearer/closed' ] \
    && ok "A2 the four routes are in ROUTES, not OPEN_ROUTES" || bad "A2 route wiring: $ROUTED"

  echo "A3: console-ui/src/lib/ai-accounts.js and console-ui/src/lib/envelope.js, driven"
  OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
import { checkAiAccountLabel, chooseAccount } from './src/lib/ai-accounts.js';
import { accountScope } from './src/lib/envelope.js';
const out = [];
out.push(['sk-x', 'SK-proj-1', 'xai-abc', 'shared', 'Team-A'].every((v) => !checkAiAccountLabel(v).ok && !checkAiAccountLabel(v).message.includes(v)) ? 'labels-refused' : 'labels-BAD');
out.push(checkAiAccountLabel('team-a').ok ? 'label-ok' : 'label-BAD');
out.push(accountScope({ vendor: 'openrouter', label: 'team-a', use_kind: 'pool' }).scope);
out.push(accountScope({ vendor: 'claude', label: 'team-a', use_kind: 'pool', project: 'demo' }).ok ? 'project-BAD' : 'project-refused');
const writes = [];
const setter = { set: async (row, v) => { writes.push(row.project + '=' + v); return { status: 'written' }; } };
await chooseAccount({ choice: { kind: 'pool' }, project: 'demo', setter });
out.push(writes.join(','));
out.push((await chooseAccount({ choice: { kind: 'own' }, project: 'demo', setter })).status);
console.log(out.join(' '));" 2>&1)
  [ "$OUT" = 'labels-refused label-ok ai-account:openrouter:team-a:pool project-refused demo=shared open-add' ] \
    && ok "A3 label rule, scope grammar and the pool choice" || bad "A3 console libs: $OUT"

  # A skipped test gates nothing, the same rule as the worker-jobs skip guard
  # in harness-ci.yml.
  skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }
  echo "A5: worker/jobs/test/ai-accounts.bh-7966.test.js and ai-accounts-explain.bh-7966.test.js"
  OUT=$(cd "$DIR/worker/jobs" && node --test test/ai-accounts.bh-7966.test.js test/ai-accounts-explain.bh-7966.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "A5 the worker ai-accounts suites, 0 skipped"
  else bad "A5 the worker ai-accounts suites failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi
fi

echo "ai-accounts.bh-7966: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
