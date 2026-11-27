#!/bin/bash
# tests/log-period-console.bh-9308-test.sh — the log screens' period helpers
# (BH-9308, BH-9120.4): console-ui/src/lib/log-period.js.
#
# WHY A SHELL SUITE AS WELL. The screens' behaviour is proved by node --test in
# console-ui/tests/log-period.bh-9120-4.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the lib by path, drives its pure half for real, and holds the four
# screens to the rules a reviewer would otherwise check by eye
# (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/log-period.js, DRIVEN: readLogParams reads exactly the asked keys
#      (empty = null), logHref drops the cursor and removes a null/'' change,
#      logCsvHref keeps only the filters with a value, seriesBucket keeps an
#      explicit bucket, logPollMs is 0 for an ended range.
#   2. the four screens import the lib, and the lib uses the shared
#      SortableTable and no native dialog.
#   3. the node suite console-ui/tests/log-period.bh-9120-4.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/log-period-console.bh-9308-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/log-period.js"
SCREENS=("$DIR/console-ui/src/screens/Jobs.js" "$DIR/console-ui/src/screens/LaneRuns.js"
         "$DIR/console-ui/src/screens/History.js" "$DIR/console-ui/src/screens/CommandHistory.js")

for f in "$LIB" "${SCREENS[@]}"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the shape (no node needed) -------------------------------------------
for s in "${SCREENS[@]}"; do
  grep -q "from '../lib/log-period.js'" "$s" && ok || bad "$(basename "$s") must use lib/log-period.js"
done
grep -q "from '../ui/SortableTable.js'" "$LIB" && ok || bad "log-period.js must use the shared SortableTable"
CODE=$(grep -hvE '^[[:space:]]*//' "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in log-period.js"
else
  ok
fi

command -v node >/dev/null 2>&1 || { echo "log-period-console: node SKIPPED — node is not installed on this box"; echo "log-period-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "log-period-console: lib drive and node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
  echo "log-period-console: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# --- 1: the lib, driven (the clock is a pinned literal) ----------------------
OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
import { LOG_KEYS, readLogParams, logHref, logCsvHref, seriesBucket, logPollMs }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const NOW = Date.parse('2026-11-20T12:00:00Z');

eq('keys-jobs',      LOG_KEYS.jobs, ['q', 'project', 'lane', 'status', 'sort', 'dir']);
eq('keys-frozen',    Object.isFrozen(LOG_KEYS), true);
eq('read',           readLogParams('?q=abc&project=&lane=x&other=1', ['q', 'project', 'lane']),
                     { q: 'abc', project: null, lane: 'x' });
eq('read-empty',     readLogParams('', ['q']), { q: null });
eq('href-cursor',    logHref('/jobs', '?from=a&cursor=9&q=x', { q: 'y' }), '/jobs?from=a&q=y');
eq('href-remove',    logHref('/jobs', '?q=x&lane=l', { q: null, lane: '' }), '/jobs');
const csv = logCsvHref('/api/jobs', { from: '2026-11-01T00:00:00Z', to: '2026-11-02T00:00:00Z' },
                       { q: 'x', project: null, lane: '' });
eq('csv-format',     csv.includes('format=csv'), true);
eq('csv-keeps-q',    csv.includes('q=x'), true);
eq('csv-drops-null', csv.includes('project=') || csv.includes('lane='), false);
eq('bucket-explicit', seriesBucket({ from: '2026-11-01T00:00:00Z', bucket: 'week' }, NOW), 'week');
eq('poll-ended',     logPollMs({ from: '2026-11-01T00:00:00Z', to: '2026-11-02T00:00:00Z' }, NOW, 5000), 0);
eq('poll-open',      logPollMs({ from: '2026-11-01T00:00:00Z', to: null }, NOW, 5000), 5000);
eq('poll-future',    logPollMs({ from: '2026-11-01T00:00:00Z', to: '2026-12-01T00:00:00Z' }, NOW, 5000), 5000);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *)     [ -n "$line" ] && bad "lib: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suite, driven -----------------------------------------------
if NOUT=$(cd "$DIR/console-ui" && node --test tests/log-period.bh-9120-4.test.js 2>&1); then ok
else bad "console-ui/tests/log-period.bh-9120-4.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "log-period-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
