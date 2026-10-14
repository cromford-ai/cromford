#!/bin/bash
# tests/machines-orgo-ui.bh-5750-test.sh — the /machines box controls
# (BH-5750 C3/C4/C5/C6): Orgo row RESTART / RESIZE / STOP / RETIRE, the priced
# confirm, the ORGO STATE and SPECS columns, LAUNCH BOX and the Fly pool
# CAP / ONBOARD TO POOL controls.
#
# WHY A SHELL SUITE AS WELL. The screen is proved by four node suites in
# console-ui/tests/ (reached through the console-ui job). This file is the
# part the impact lane and the orphan ratchet can SEE (D41): it names every
# new source by path, drives the two pure libs for real, holds the screen to
# the touched-file rules (shared SortableTable, in-app modal, no native
# dialog), and runs the node suites when the console-ui deps are installed.
#
#   1. lib/box-op-detail.js, DRIVEN: the figure is the worker's rule (first
#      COST:/PLAN cost line; an ok resize with neither is "0"; a launch
#      without usd_mo has none), a fail quote is never confirmable, NEXT:
#      fields come apart, a fail row's WAITING/NEEDS PURCHASE/refused tag.
#   2. lib/orgo-state.js, DRIVEN: the box id per row name (hub and an
#      all-number fleet name get none), unknown / gone / stale / not
#      available, and pool membership.
#   3. BoxOpForms.js and Machines.js: no native dialog, useConfirm for the
#      dialogs, SortableTable for the tables.
#   4. the node suites, run for real when the console-ui deps are installed.
# Run from anywhere: tests/machines-orgo-ui.bh-5750-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DETAIL="$DIR/console-ui/src/lib/box-op-detail.js"
STATE="$DIR/console-ui/src/lib/orgo-state.js"
FORMS="$DIR/console-ui/src/ui/BoxOpForms.js"
SCREEN="$DIR/console-ui/src/screens/Machines.js"
WORKER_ARGS="$DIR/worker/jobs/src/lib/box-command-args.js"

for f in "$DETAIL" "$STATE" "$FORMS" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "machines-orgo-ui: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1 + 2: the pure libs, driven ---------------------------------------------
OUT=$(node --input-type=module -e "
import { quoteFigure, quoteView, detailView, failTag, QUOTE_POLL } from '$DETAIL';
import { quoteFigure as workerFigure } from '$WORKER_ARGS';
import { orgoBoxIds, shapeOrgoComputers, orgoStateFor, specsText, flyOnPool, parsePositiveInt, STALE_MIN } from '$STATE';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const PLAN = 'box-ops: verb=resize id=alpha result=plan rc=0 | PLAN cost +\$12/mo (now \$40/mo, after \$52/mo); --apply needs --confirm-monthly-usd 12';
for (const [t, d] of [['orgo_resize_quote', PLAN], ['orgo_resize_quote', 'COST: resize alpha +\$15/mo | PLAN cost +\$12/mo'],
  ['orgo_resize_quote', 'PLAN shrink'], ['orgo_launch_quote', 'box-launch: box=g usd_mo=40 smoke=x'], ['orgo_launch_quote', 'capacity: fits 1']]) {
  eq('figure-same-as-worker ' + d, quoteFigure(t, d), workerFigure(t, d));
}
eq('figure-plan',      quoteFigure('orgo_resize_quote', PLAN), '12');
eq('figure-shrink',    quoteFigure('orgo_resize_quote', 'box-ops: verb=resize result=plan'), '0');
eq('figure-launch-no', quoteFigure('orgo_launch_quote', 'capacity: fits 1'), null);
eq('view-ok',          quoteView({ type: 'orgo_resize_quote', status: 'ok', detail: PLAN }).confirmable, true);
eq('view-fail',        quoteView({ type: 'orgo_resize_quote', status: 'fail', detail: PLAN }).confirmable, false);
eq('view-pending',     quoteView({ type: 'orgo_resize_quote', status: 'claimed', detail: null }).phase, 'pending');
eq('poll-defaults',    QUOTE_POLL, { intervalMs: 5000, timeoutMs: 180000 });
eq('next-split',       detailView('box-ops: verb=stop result=ok | NEXT: lift with x | NEXT: then y').next, ['NEXT: lift with x', 'NEXT: then y']);
eq('tag-waiting',      failTag({ status: 'fail', detail: 'a | WAITING: pr' }), 'WAITING');
eq('tag-refused',      failTag({ status: 'fail', detail: 'refused: no root' }), 'REFUSED');
eq('tag-ok',           failTag({ status: 'ok', detail: 'WAITING: x' }), null);

eq('ids',              orgoBoxIds(['hub', 'bw-1', 'bw-alpha-2', 'bw-beta']), { hub: 'hub', 'bw-1': null, 'bw-alpha-2': 'alpha', 'bw-beta': 'beta' });
const now = Date.parse('2026-10-10T12:00:00Z');
const o = shapeOrgoComputers({ computers: [
  { orgo_id: 'oc-fixture-1', name: 'bw-alpha-2', status: 'running', cpu: 4, ram_gb: 16, disk_gb: 100, seen_at: '2026-10-10T11:58:00Z', gone_at: null },
  { orgo_id: 'oc-fixture-2', name: 'bw-beta', status: 'stopped', seen_at: '2026-10-10T11:00:00Z', gone_at: null },
  { orgo_id: 'oc-fixture-3', name: 'bw-gone', status: 'running', seen_at: '2026-10-10T10:00:00Z', gone_at: '2026-10-10T11:00:00Z' } ], accounts: {} });
eq('state-running',    orgoStateFor('bw-alpha-2', o, now).text, 'running');
eq('state-stale',      orgoStateFor('bw-beta', o, now).stale, true);
eq('state-gone',       orgoStateFor('bw-gone', o, now).state, 'gone');
eq('state-unknown',    orgoStateFor('bw-none', o, now).state, 'unknown');
eq('state-unavail',    orgoStateFor('bw-none', { unavailable: true }, now).state, 'not available');
eq('stale-min',        STALE_MIN, 15);
eq('specs',            specsText(o.byName['bw-alpha-2'][0]), '4c/16gb/100gb');
eq('pool-app',         flyOnPool('p', { apps: ['pool-p'] }), true);
eq('pool-none',        flyOnPool('p', { apps: ['builder-p'], machines: [] }), false);
eq('int',              [parsePositiveInt('5'), parsePositiveInt('0'), parsePositiveInt('2.5'), parsePositiveInt(' ')], [5, null, null, undefined]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the screen's shape ----------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Machines.js must use the shared SortableTable"
grep -q "useConfirm" "$SCREEN" && ok || bad "Machines.js must confirm through the in-app useConfirm modal"
grep -q "from '../ui/BoxOpForms.js'" "$SCREEN" && ok || bad "Machines.js must mount the BoxOpForms controls"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$FORMS" "$DETAIL" "$STATE")
# A bare confirm( here is the app's own useConfirm function (deps.confirm,
# the useConfirm pair); window.confirm, alert( and prompt( never are.
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\(|(^|[^A-Za-z_.])(alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog call in the /machines box controls: ${BASH_REMATCH[0]}"
else
  ok
fi

# --- 4: the node suites, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "machines-orgo-ui: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in machines-orgo-actions machines-orgo-state machines-launch machines-fly-pool; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "tests/$t.bh-5750.test.js" 2>&1); then ok
    else bad "console-ui/tests/$t.bh-5750.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "machines-orgo-ui: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
