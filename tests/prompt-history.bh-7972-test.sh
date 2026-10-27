#!/bin/bash
# tests/prompt-history.bh-7972-test.sh — BH-7972 (BH-7940.4): the prompt marker
# lint, the version history routes (list, restore, drop head), the
# prompt_versions retention rule, and the console VERSIONS sheet and USE LEVEL
# ABOVE button.
#
# The behaviour is proved by node --test. This file names every new source by
# path, so the impact lane and the orphan ratchet can see them, and:
#   1. every new source and suite exists;
#   2. the route family is in ROUTES (behind the bearer), and GET …/versions
#      matches it before the contract's GET …/:version row;
#   3. the worker suites (worker/jobs/test/prompt-history.bh-7972.test.js and
#      worker/jobs/test/prompts-explain.bh-7972.test.js) pass with 0 skipped;
#   4. the console suite (console-ui/tests/prompt-history.bh-7972.test.js),
#      run for real when console-ui/node_modules is installed. Every fetch in
#      it is a stub that refuses a URL outside /api/prompts: 0 vendor calls.
# Run from anywhere: tests/prompt-history.bh-7972-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$DIR/catalog/prompt-markers.json" \
         "$DIR/worker/jobs/src/routes/prompt-history.js" \
         "$DIR/worker/jobs/test/route-table.d/bh-7940-prompt-history.txt" \
         "$DIR/worker/jobs/src/routes/retention.d/bh-7972-prompt-versions.js" \
         "$DIR/worker/jobs/schema.d/202610270710-bh-7972-prompt-history-knobs.sql" \
         "$DIR/console-ui/src/lib/prompt-history.js" \
         "$DIR/console-ui/src/ui/PromptHistoryActions.js" \
         "$DIR/worker/jobs/test/prompt-history.bh-7972.test.js" \
         "$DIR/worker/jobs/test/prompts-explain.bh-7972.test.js" \
         "$DIR/console-ui/tests/prompt-history.bh-7972.test.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "prompt-history.bh-7972: FAIL — node is not installed on this box"; exit 1; }
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }

# A skipped test gates nothing (the worker-jobs skip guard in harness-ci.yml).
skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }

# --- 2: the route table --------------------------------------------------------
ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
import { routes } from './src/routes/prompt-history.js';
const q = [['GET', '/api/prompts/project/plan/versions'], ['POST', '/api/prompts/project/plan/restore'], ['DELETE', '/api/prompts/fleet/rules/head']];
const out = q.map(([m, p]) => {
  const hit = matchRoute(ROUTES, m, p);
  const own = hit && routes.some((r) => r[2] === hit.handler);
  return (own ? 'history' : hit ? 'other' : 'none') + '/' + (matchRoute(OPEN_ROUTES, m, p) ? 'open' : 'closed');
});
console.log(out.join(' '));" 2>&1)
[ "$ROUTED" = 'history/closed history/closed history/closed' ] && ok || bad "route wiring: $ROUTED"

# --- 3: the worker suites --------------------------------------------------------
OUT=$(cd "$DIR/worker/jobs" && node --test test/prompt-history.bh-7972.test.js test/prompts-explain.bh-7972.test.js 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok
else bad "the worker prompt-history suites failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi

# --- 4: the console suite --------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "prompt-history.bh-7972: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  OUT=$(cd "$DIR/console-ui" && node --test tests/prompt-history.bh-7972.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok
  else bad "console-ui/tests/prompt-history.bh-7972.test.js failed:"; printf '%s\n' "$OUT" | grep -E '^not ok|Error' | head -20; fi
fi

echo "prompt-history.bh-7972: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
