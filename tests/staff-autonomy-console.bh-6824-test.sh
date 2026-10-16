#!/bin/bash
# tests/staff-autonomy-console.bh-6824-test.sh — the AUTONOMY panel on the
# staff agent page (BH-6824, Staff in Mission Control 3/4).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/staff-autonomy.bh-6824.test.js and
# worker/jobs/test/staff-autonomy.bh-6824.test.js. This file is the part the
# impact lane and the orphan ratchet can SEE (the cost-breaker-console.bh-2331
# pattern): it names the new sources by path, drives the pure half, and holds
# the panel to the rules a reviewer would otherwise check by eye.
#
#   1. lib/staff-autonomy.js, DRIVEN: the level options stop at the cap, no
#      body is built above the cap, for a blank reason or for a protected
#      class, and a failed read is null, never an empty list.
#   2. the panel uses the shared SortableTable and the in-app Modal, never a
#      native dialog; Staff.js mounts it; the coord fragment requires a reason.
#   3. the two node suites, run for real when node (and, for the console one,
#      the console-ui dependencies) are installed.
# Run from anywhere: tests/staff-autonomy-console.bh-6824-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# worker/jobs/src/index.js imports catalog/lanes.json and catalog/llm-sites.json,
# both git-ignored: build them first (BH-6540, BH-6452).
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/staff-autonomy.js"
PANEL="$DIR/console-ui/src/screens/staff/agent-autonomy.js"
STAFF="$DIR/console-ui/src/screens/Staff.js"
FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/6824-staff-autonomy.js"
ROUTE="$DIR/worker/jobs/src/routes/staff-autonomy.js"

for f in "$LIB" "$PANEL" "$STAFF" "$FRAG" "$ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "staff-autonomy-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { autonomyState, levelOptions, autonomyBody, delegationBody, errorText } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('options-cap-autonomy',    levelOptions('automation', 'autonomy'), ['augmentation', 'autonomy']);
eq('options-cap-augmentation', levelOptions('automation', 'augmentation'), ['augmentation']);
eq('options-at-cap',          levelOptions('automation', 'automation'), []);
eq('body-above-cap',          autonomyBody('watchman', 'autonomy', 'augmentation', 'r'), null);
eq('body-blank-reason',       autonomyBody('watchman', 'augmentation', 'augmentation', '  '), null);
eq('body-ok',                 autonomyBody('watchman', 'augmentation', 'augmentation', ' r '), { agent: 'watchman', autonomy: 'augmentation', reason: 'r' });
eq('protected-never-sent',    delegationBody('watchman', { class: 'deploy', state: 'ask_first', protected: true, effective_cap: 'autonomy' }, 'r'), null);
eq('ask-first-body',          delegationBody('watchman', { class: 'x-y', state: 'delegated', protected: false, effective_cap: 'autonomy' }, 'r'),
  { agent: 'watchman', class: 'x-y', decision: 'ask_first', reason: 'r' });
eq('failed-read-null',        autonomyState({ error: 'agent not found' }), null);
eq('empty-read',              autonomyState({ agent: { name: 'a' }, classes: [], changes: [] }).classes, []);
eq('not-earned-text',         errorText({ error: 'not_earned', streak: 2, min_streak: 5 }), 'refused: needs 5 agreements in a row, has 2.');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the panel's shape ---------------------------------------------------
grep -q "from '../../ui/SortableTable.js'" "$PANEL" && ok || bad "agent-autonomy.js must use the shared SortableTable"
grep -q "from '../../ui/Modal.js'" "$PANEL" && ok || bad "agent-autonomy.js must edit in the in-app Modal"
grep -q "AgentAutonomy} agent=" "$STAFF" && ok || bad "Staff.js must mount AgentAutonomy on the agent page"
[ "$(grep -c "needsReason: true" "$FRAG")" -eq 2 ] && ok || bad "both coord rows in $FRAG must require a reason"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the AUTONOMY panel"
else
  ok
fi

# --- 3: the node suites, driven ---------------------------------------------
if WOUT=$(cd "$DIR/worker/jobs" && node --test test/staff-autonomy.bh-6824.test.js 2>&1); then ok
else bad "worker/jobs/test/staff-autonomy.bh-6824.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^ *not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-autonomy-console: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/staff-autonomy.bh-6824.test.js 2>&1); then ok
  else bad "console-ui/tests/staff-autonomy.bh-6824.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "staff-autonomy-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
