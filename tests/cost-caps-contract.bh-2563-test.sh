#!/bin/bash
# tests/cost-caps-contract.bh-2563-test.sh — the cost-caps contract slice
# (BH-2563, BH-2511.0) as the impact lane and the orphan ratchet can SEE it.
#
#   M1. the two Costs-page mount points exist, named here by rooted path.
#   M2. Costs.js mounts them directly below CostBreakerSection, CAPS first
#       then HISTORY, on consecutive lines.
#   M3. each mount point exports a function (CAPS is BH-2566, HISTORY is
#       BH-2567); both are imported only with the console deps.
#   P1. the coord proxy forwards a PUT `cost-caps` once, with the allowlisted
#       fields only and actor stamped `console`, and no query string.
#   P2-P4. POST/PUT `cost-caps/seed` and POST/DELETE `cost-caps` are 405 and
#       reach nothing: the seed is hub-bearer only.
#   N. the two node suites that own the rest of the contract
#      (worker/jobs and console-ui cost-caps-contract.bh-2563.test.js).
# Run from anywhere: tests/cost-caps-contract.bh-2563-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

CAPS="$DIR/console-ui/src/screens/CostCaps.js"
HISTORY="$DIR/console-ui/src/screens/CostCapHistory.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

# --- M1: the files -----------------------------------------------------------
for f in "$CAPS" "$HISTORY" "$COSTS" "$PROXY"; do
  [ -f "$f" ] && ok || bad "M1: missing $f"
done

# --- M2: the mounts, in order, consecutive ----------------------------------
# A missing symbol is line 0 and fails; it never passes as "in order".
line_of() { grep -nF -- "$1" "$COSTS" 2>/dev/null | head -1 | cut -d: -f1; }
LB=$(line_of '<${CostBreakerSection}/>'); LB=${LB:-0}
LC=$(line_of '<${CostCapsSection}/>'); LC=${LC:-0}
LH=$(line_of '<${CostCapHistorySection}/>'); LH=${LH:-0}
if [ "$LB" -gt 0 ] && [ "$LC" -eq $((LB+1)) ] && [ "$LH" -eq $((LC+1)) ]; then ok
else bad "M2: Costs.js mounts breaker=$LB caps=$LC history=$LH (want consecutive, CAPS then HISTORY)"; fi
grep -qF "import { CostCapsSection } from './CostCaps.js';" "$COSTS" && ok || bad "M2: Costs.js does not import CostCapsSection"
grep -qF "import { CostCapHistorySection } from './CostCapHistory.js';" "$COSTS" && ok || bad "M2: Costs.js does not import CostCapHistorySection"

command -v node >/dev/null 2>&1 || { echo "cost-caps-contract: SKIPPED the node cases — node is not installed on this box"; echo "cost-caps-contract: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit; }

# --- M3: the mount points are exported functions -----------------------------
# BH-2566 filled in CostCapsSection and BH-2567 CostCapHistorySection: both
# import preact now (a bare call throws, and neither loads without
# console-ui/node_modules), so their renders belong to
# tests/cost-caps-console.bh-2511-test.sh and
# tests/cost-cap-history-console.bh-2511-test.sh. Here they are imported when
# the console deps are installed, and otherwise their exports are read from
# the source.
DEPS=0; [ -d "$DIR/console-ui/node_modules/preact" ] && DEPS=1
if [ "$DEPS" = 1 ]; then
  OUT=$(node --input-type=module -e "
import { CostCapsSection } from '$CAPS';
import { CostCapHistorySection } from '$HISTORY';
console.log(typeof CostCapsSection === 'function' && typeof CostCapHistorySection === 'function' ? 'ok' : 'no');
" 2>&1)
  [ "$OUT" = ok ] && ok || bad "M3: a mount point is not an exported function: $OUT"
else
  grep -q '^export function CostCapsSection(' "$CAPS" && ok || bad "M3: CostCaps.js does not export function CostCapsSection"
  grep -q '^export function CostCapHistorySection(' "$HISTORY" && ok || bad "M3: CostCapHistory.js does not export function CostCapHistorySection"
fi

# --- P1-P4: the coord proxy row ---------------------------------------------
OUT=$(node --input-type=module -e "
import { onRequest } from '$PROXY';
const JOBS = 'https://harness-jobs.operator.workers.dev';
let seen = [];
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
  seen.push({ url, method: init.method, body: init.body });
  return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
};
let n = 0;
const call = (rest, method, body, search = '') => onRequest({
  request: new Request('https://console.example.pages.dev/api/coord/' + rest + search,
    { method, headers: { cookie: 'dash=bh2563-sh-' + (++n), 'content-type': 'application/json' }, body }),
  env: { HARNESS_SECRET: 's' }, params: { path: rest.split('/') } });
const say = (name, cond, got) => console.log((cond ? 'ok ' : 'no ') + name + ' ' + JSON.stringify(got));

seen = [];
let r = await call('cost-caps', 'PUT', JSON.stringify({ key: 'conf.cost-caps.default', value: '100 5', reason: 'r', actor: 'mallory', smuggled: 1 }), '?actor=m');
const want = JSON.stringify({ key: 'conf.cost-caps.default', value: '100 5', reason: 'r', actor: 'console' });
say('P1', r.status === 200 && seen.length === 1 && seen[0].url === JOBS + '/api/cost-caps'
  && seen[0].method === 'PUT' && seen[0].body === want, { status: r.status, seen });

for (const [name, rest, method] of [['P2', 'cost-caps/seed', 'POST'], ['P3', 'cost-caps/seed', 'PUT'],
                                    ['P4-post', 'cost-caps', 'POST'], ['P4-delete', 'cost-caps', 'DELETE']]) {
  seen = [];
  r = await call(rest, method, method === 'DELETE' ? undefined : JSON.stringify({ rows: [], key: 'k', value: 'v' }));
  say(name, r.status === 405 && seen.length === 0, { status: r.status, seen: seen.length });
}
" 2>&1)
for c in P1 P2 P3 P4-post P4-delete; do
  grep -q "^ok $c " <<<"$OUT" && ok || bad "$c: $(grep "^no $c " <<<"$OUT" || echo "$OUT")"
done

# --- N: the node suites -----------------------------------------------------
# WORKER_JOBS_CI_JOB=1 is set by harness-ci.yml's tests-shard step, which runs
# only when the "Jobs worker — routes + schema" job runs too (both need
# corpus == '1'). That job runs `npm test` in worker/jobs, which covers every
# test/*.test.js file, so running these node files again in a shard is the same
# test twice. Without the flag (a builder's bin/test-impact-gate.sh, a laptop)
# they run here. tests/dedicated-job-coverage-test.sh checks all of this.
if [ "${WORKER_JOBS_CI_JOB:-}" = 1 ]; then
  echo "cost-caps-contract: worker/jobs node suites not repeated here — the Jobs worker CI job runs them on this run"
else
  # core.js imports the GENERATED, git-ignored catalog/lanes.json statically, so
  # it is rendered into the checkout first (the controls-contract.bh-2513 way).
  if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
    "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
      || { echo "FAIL: cost-caps-contract: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
  fi
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/cost-caps-contract.bh-2563.test.js test/route-table.test.js 2>&1); then ok
  else bad "N: worker/jobs cost-caps-contract / route-table suite failed"; echo "$NOUT" | grep -E 'not ok|Error|expected|actual' | head -20; fi
fi
# The console-ui file imports CostCaps.js and CostCapHistory.js, which need the
# console deps since BH-2566/BH-2567; without them it says so and skips (the
# console-ui CI job runs it).
if [ "$DEPS" != 1 ]; then
  echo "cost-caps-contract: console-ui node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-caps-contract.bh-2563.test.js 2>&1); then ok
else bad "N: console-ui cost-caps-contract suite failed"; echo "$NOUT" | grep -E 'not ok|Error|expected|actual' | head -20; fi

echo "cost-caps-contract: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
