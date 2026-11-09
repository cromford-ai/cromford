#!/bin/bash
# tests/waiting-view.bh-9116-test.sh — BH-9116: the "To do (waiting)" view on
# KANBAN and /p/<project>.
#
# The behaviour is proved by node --test in console-ui/tests/waiting.bh-9116.test.js,
# console-ui/tests/waiting-nav.bh-9116.test.js (the console-ui CI job) and
# worker/jobs/test/waiting.bh-9116.test.js (the worker CI job). This file is the
# part the impact lane and the orphan ratchet can SEE (the
# build-order-console.bh-6980 pattern):
#   1. console-ui/src/lib/waiting.js, DRIVEN: one ticket per reason, the
#      deferral matcher, dropStaleClaims.
#   2. the wiring: the KANBAN tab, the Project QUEUES panel, api.waiting, the
#      route fragment, the knob rows.
#   3. the node suites, run for real when their dependencies are present.
# Run from anywhere: tests/waiting-view.bh-9116-test.sh   (exit 0 = all pass)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$REPO" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$REPO/console-ui/src/lib/waiting.js"
FN="$REPO/console-ui/functions/api/dash/kanban/waiting.js"
PANEL="$REPO/console-ui/src/screens/WaitingPanel.js"
KANBAN="$REPO/console-ui/src/screens/Kanban.js"
PROJECT="$REPO/console-ui/src/screens/Project.js"
API="$REPO/console-ui/src/api.js"
ROUTE="$REPO/worker/jobs/src/routes/waiting.js"
FRAG="$REPO/worker/jobs/test/route-table.d/bh-9116-waiting.txt"
SEED="$REPO/worker/jobs/schema.d/202611090506-bh-9116-waiting-settings.sql"
for f in "$LIB" "$FN" "$PANEL" "$KANBAN" "$PROJECT" "$API" "$ROUTE" "$FRAG" "$SEED"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "waiting-view: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { classifyWaiting, dropStaleClaims, isDeferral } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const NOW = Date.parse('2026-11-05T22:00:00Z');
const ago = (m) => new Date(NOW - m * 60000).toISOString();
const tk = (key, o = {}) => ({ key, status: 'todo', title: key, updatedAt: ago(60), triage_verdict: 'untriaged', waiting_on: '', ...o });
const snap = { generated_at: NOW / 1000, projects: { 'project-3': { tickets: [
  tk('A'), tk('B', { waiting_on: 'client' }), tk('C', { triage_verdict: 'buildable' }), tk('D', { triage_verdict: 'buildable' }),
  tk('E', { triage_verdict: 'buildable' }), tk('F', { triage_verdict: 'buildable' }), tk('G', { triage_verdict: 'buildable' }),
  tk('H', { triage_verdict: 'triaged' }), tk('Z', { status: 'done' }) ] } } };
const q = (k, status, o = {}) => ({ project: 'project-3', ticket_key: k, status, enqueued_at: ago(10), updated_at: ago(10), ...o });
const st = { triage: [], live_jobs: [], parked_jobs: [], knobs: { stale_claim_min: 30 },
  queue: [q('E', 'queued'), q('F', 'failed', { reason: 'BUILD_DEFERRED wip limit' }), q('G', 'claimed', { claimed_at: ago(45) })],
  positions: [{ project: 'project-3', ticket_key: 'E' }], edges: [{ project: 'project-3', parent: 'A', child: 'C', kind: 'hard' }] };
const out = classifyWaiting(snap, st, { now: NOW });
eq('one reason per ticket', Object.fromEntries(out.rows.map((r) => [r.key, r.reason])),
  { A: 'not-triaged', B: 'needs-clarification', C: 'blocked-by', D: 'ready-not-queued', E: 'queued', F: 'deferred', G: 'stale-claim', H: 'other' });
eq('counts sum to rows', Object.values(out.counts).reduce((a, b) => a + b, 0), out.rows.length);
eq('deferral positive', isDeferral('BUILD_DEFERRED lock held on box-2'), true);
eq('deferral negative', isDeferral('deferred to the user'), false);
const b = dropStaleClaims({ columns: { building: [{ id: 1, project: 'project-3', ticket: 'G' }, { id: 2, project: 'project-4', ticket: 'G' }] }, counts: { building: 2 } }, out);
eq('stale claim dropped from BUILDING', [b.counts.building, b.columns.building.map((c) => c.id)], [1, [2]]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring ------------------------------------------------------------
grep -qF ">TO DO (WAITING)</button>" "$KANBAN" && ok || bad "Kanban.js must carry the TO DO (WAITING) tab"
grep -qF "dropStaleClaims(filterPipeline(p.data, project), waiting.data)" "$KANBAN" && ok || bad "the PIPELINE board must drop stale claims"
grep -qF '<${WaitingPanel} project=${project}/>' "$PROJECT" && ok || bad "Project.js QUEUES must render WaitingPanel"
grep -qF "get('/api/dash/kanban/waiting'" "$API" && ok || bad "api.js must carry api.waiting"
grep -qxF "POST /api/waiting/state" "$FRAG" && ok || bad "the route fragment must list POST /api/waiting/state"
for k in waiting.stale_claim_min waiting.max_tickets waiting.defer_lookback_min waiting.reason_text_max; do
  grep -qF "('$k'," "$SEED" && ok || bad "the seed must carry $k"
done

# --- 3: the node suites, driven ---------------------------------------------
if [ ! -d "$REPO/console-ui/node_modules/preact-render-to-string" ]; then
  echo "waiting-view: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
elif [ ! -f "$REPO/catalog/lanes.json" ] || [ ! -f "$REPO/catalog/context-budgets.json" ]; then
  echo "waiting-view: node suites SKIPPED — catalog/lanes.json or catalog/context-budgets.json is not rendered (bin/lanes-build.sh --write, bin/context-budgets-build.sh --compose)"
else
  if NOUT=$(cd "$REPO/console-ui" && node --test tests/waiting.bh-9116.test.js tests/waiting-nav.bh-9116.test.js 2>&1); then ok
  else bad "console-ui waiting suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi
if [ -f "$REPO/catalog/lanes.json" ] && [ -f "$REPO/catalog/context-budgets.json" ] && [ -f "$REPO/catalog/llm-sites.json" ]; then
  if WOUT=$(cd "$REPO/worker/jobs" && node --test test/waiting.bh-9116.test.js 2>&1); then ok
  else bad "worker/jobs/test/waiting.bh-9116.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "waiting-view: worker node suite SKIPPED — the catalog renders the worker imports are not present"
fi

echo "waiting-view: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
