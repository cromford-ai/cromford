#!/bin/bash
# tests/queue-risk-record.bh-5430-test.sh — the record of the merge-queue
# break-risk score and its Mission Control badge (BH-5430, slice S4).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by two node suites:
# worker/jobs/test/queue-risk.bh-5430.test.js (the route, W1-W5) and
# console-ui/tests/queue-risk.bh-5430.test.js (the badge, C1-C5). What this file
# adds is the part the impact lane and the orphan ratchet can SEE: it names the
# new sources by path, drives the pure console lib for real, and runs both
# node suites (the cost-breaker-console.bh-2331 pattern).
#
#   1. console-ui/src/lib/queue-risk.js, DRIVEN: newest row per repo#pr, the
#      badge for solo / batch / no row, and the reasons in plain words.
#   2. the worker route is registered in src/index.js and has its own
#      route-table fragment; the MergeQueue screen reads it.
#   3. the worker node suite (node:sqlite, no npm deps) and the console node
#      suite (when the console-ui dependencies are installed).
# Run from anywhere: tests/queue-risk-record.bh-5430-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/queue-risk.js"
LIB="$DIR/console-ui/src/lib/queue-risk.js"
SCREEN="$DIR/console-ui/src/screens/MergeQueue.js"
INDEX="$DIR/worker/jobs/src/index.js"
FRAG=""
for f in "$DIR"/worker/jobs/test/route-table.d/*-queue-risk.txt; do [ -f "$f" ] && FRAG="$f"; done

for f in "$ROUTE" "$LIB" "$SCREEN" "$INDEX"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ "$FAIL" -gt 0 ] && { echo "queue-risk-record: $PASS passed, $FAIL failed"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "queue-risk-record: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the console lib, driven ---------------------------------------------
OUT=$(node --input-type=module -e "
import { QR_READ_LIMIT, latestByPr, riskBadge, reasonLines } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const R = 'example-org/cromford';
const m = latestByPr([
  { id: 1, repo: R, pr: 7, updated_at: '2026-10-08T10:00:00Z', route: 'batch', score: 0 },
  { id: 2, repo: R, pr: 7, updated_at: '2026-10-08T12:00:00Z', route: 'solo', score: 55 },
  { id: 3, repo: R, pr: 7, updated_at: '2026-10-08T11:00:00Z', route: 'batch', score: 5 } ]);
eq('limit',          QR_READ_LIMIT, 200);
eq('latest',         m.get('example-org/cromford#7').id, 2);
const b = riskBadge({ route: 'solo', score: 55, reasons: 'shared_lib:+30(bin/lib/x.sh),registry:+25(catalog/y.tsv)' });
eq('badge-solo',     [b.label, b.score], ['solo', 55]);
eq('badge-title',    b.title, 'shared lib +30 (bin/lib/x.sh), registry +25 (catalog/y.tsv)');
eq('badge-none',     riskBadge(null).label, '—');
eq('badge-batch',    riskBadge({ route: 'batch', score: null, reasons: 'files-unavailable' }).label, 'batch');
eq('lines',          reasonLines('ejected_before:+50(2 prior culprit verdicts)').map((l) => [l.signal, l.weight, l.path]),
                     [['ejected before', 50, '2 prior culprit verdicts']]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring ----------------------------------------------------------
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-queue-risk.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "queue-risk has no route-table.d fragment (BH-4607: the fragment IS the registration)"
grep -q 'from "./routes/queue-risk.js"' "$INDEX" && bad "index.js hand-registers queue-risk: the fragment registers it (BH-4607)" || ok
if [ -n "$FRAG" ] && grep -qx 'POST /api/queue-risk' "$FRAG" && grep -qx 'GET /api/queue-risk' "$FRAG"; then ok
else bad "worker/jobs/test/route-table.d/<NNN>-queue-risk.txt must list POST and GET /api/queue-risk"
fi
grep -q "api.queueRisk" "$SCREEN" && ok || bad "MergeQueue.js must read api.queueRisk"
grep -q "from '../lib/queue-risk.js'" "$SCREEN" && ok || bad "MergeQueue.js must use lib/queue-risk.js"

# --- 3: the node suites, driven ---------------------------------------------
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/queue-risk.bh-5430.test.js 2>&1); then ok
else bad "worker/jobs/test/queue-risk.bh-5430.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "queue-risk-record: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/queue-risk.bh-5430.test.js 2>&1); then ok
  else bad "console-ui/tests/queue-risk.bh-5430.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "queue-risk-record: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
