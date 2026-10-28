#!/bin/bash
# tests/controls-contract.bh-2513-test.sh — the BH-2513 console-controls
# contract slice (BH-2617): the config_changes audit helper and the console
# controls lib (filled in by BH-2620).
#
#   1. both new sources exist at their rooted paths (the orphan ratchet reads
#      the paths below).
#   2. console-ui/src/lib/controls.js, DRIVEN: CONTROL_KINDS is the four
#      kinds, controlBody builds a real PUT body (no longer the stub's
#      'not implemented'), controlHref builds /controls/<kind>.
#   3. worker/jobs/src/lib/config-changes.js, DRIVEN: the nine CONFIG_KINDS
#      (BH-2994 added cost_cap, telegram_topic, registry_seed; BH-2375 added
#      setting, flag).
#   4. the node suite worker/jobs/test/config-changes.bh-2513.test.js, run for
#      real (the worker has no npm dependencies to wait on).
# Run from anywhere: tests/controls-contract.bh-2513-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HELPER="$DIR/worker/jobs/src/lib/config-changes.js"
CONTROLS="$DIR/console-ui/src/lib/controls.js"

for f in "$HELPER" "$CONTROLS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "controls-contract: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2 + 3: the libs, driven -------------------------------------------------
OUT=$(node --input-type=module -e "
import { CONTROL_KINDS, controlBody, controlHref } from '$CONTROLS';
import { CONFIG_KINDS } from '$HELPER';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('C1 kinds',         CONTROL_KINDS.map(d => d.kind), ['review-gate', 'rules', 'retry-policies', 'contracts', 'projects']);
eq('C2 body',          controlBody(CONTROL_KINDS[3], { phase: 'build', artifact_kind: 'pr' }, ' r '),
                       { body: { phase: 'build', artifact_kind: 'pr', pattern: '', note: '', reason: 'r' } });
eq('C2 not-stub',      controlBody({ keyFields: [], editFields: [] }, {}, 'r').error === 'not implemented', false);
eq('C3 href',          controlHref('retry_policy'), '/controls/retry_policy');
eq('C3 href-encoded',  controlHref('a b'), '/controls/a%20b');
eq('K rule',           CONFIG_KINDS.RULE, 'concurrency_rule');
eq('K all',            Object.values(CONFIG_KINDS).sort(), ['concurrency_rule', 'connection', 'cost_cap', 'flag', 'held_page', 'merge_queue', 'phase_contract', 'project', 'project_secret', 'registry_seed', 'retry_policy', 'review_gate_threshold', 'setting', 'telegram_topic']);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"
[ -n "$OUT" ] || bad "lib: node produced no output"

# --- 4: the node suite, driven -----------------------------------------------
# worker/jobs has no npm dependencies (its package.json says so), so the suite
# needs only node; it skips its own sqlite cases visibly on a runtime without
# node:sqlite. core.js imports the GENERATED, git-ignored catalog/lanes.json
# statically, so it is rendered into the checkout first (jobs-worker-test.sh
# explains why the canonical path and not a scratch dir).
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: controls-contract: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/config-changes.bh-2513.test.js 2>&1); then ok
else bad "worker/jobs/test/config-changes.bh-2513.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "controls-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
