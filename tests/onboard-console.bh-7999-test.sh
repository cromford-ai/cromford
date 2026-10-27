#!/bin/bash
# tests/onboard-console.bh-7999-test.sh — /projects/new, the two-step
# onboarding form, its coord write row and its settings rows (BH-7999,
# BH-7935.2).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/onboard.bh-7935.test.js. This file is the part the impact
# lane and the orphan ratchet can SEE: it names the new sources by path,
# drives the pure half, and runs the node suite.
#
#   1. lib/onboard.js, DRIVEN: parseSlug, deriveProject, derivePrefix, defaultTracker.
#   2. the wiring: the coord row, main.js imports onboard.css, the Fleet NEW link,
#      the settings fragment, no native dialog in the screen.
#   3. the node suite, run for real when the console dependencies are installed.
# Run from anywhere: tests/onboard-console.bh-7999-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/onboard.js"
SCREEN="$DIR/console-ui/src/screens/Onboard.js"
CSS="$DIR/console-ui/src/onboard.css"
MAIN="$DIR/console-ui/src/main.js"
FLEET="$DIR/console-ui/src/screens/Fleet.js"
WRITES="$DIR/console-ui/functions/_lib/coord-writes.d/7935-onboarding-runs.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
SEED="$DIR/worker/jobs/schema.d/202610270351-bh-7935-onboarding-board-ready.sql"
DRIVE="$DIR/console-ui/tests/drive/onboard.bh-7935-drive.mjs"
NODE_SUITE="$DIR/console-ui/tests/onboard.bh-7935.test.js"

for f in "$LIB" "$SCREEN" "$CSS" "$MAIN" "$FLEET" "$WRITES" "$PROXY" "$SEED" "$DRIVE" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "onboard-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the pure half, driven -------------------------------------------------
OUT=$(node --input-type=module -e "
const L = await import('$LIB');
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('slug-url', L.parseSlug('https://github.com/example-org/project-11.git'), { owner: 'example-org', repo: 'project-11', slug: 'example-org/project-11' });
eq('slug-bare-name', L.parseSlug('project-11'), null);
eq('slug-dotdot', L.parseSlug('owner/..'), null);
eq('project', L.deriveProject('example-org/project-11'), 'project-11');
eq('prefix', L.derivePrefix('project-11'), 'RA');
eq('prefix-fallback', L.derivePrefix('harness'), 'HA');
eq('tracker-off', L.defaultTracker({ has_issues: false }, false), null);
eq('tracker-unknown', L.defaultTracker(null, false), 'github-issues');
eq('last-line', L.reviewLines({ slug: 'a/b' }).pop().value, 'Nothing is built until a ticket is labeled.');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring -------------------------------------------------------------
grep -q "path: 'onboarding/runs'" "$WRITES" && grep -q "idempotencyKey: true" "$WRITES" && ok || bad "7935-onboarding-runs.js must hold the POST onboarding/runs row with idempotencyKey"
grep -q "row.idempotencyKey" "$PROXY" && ok || bad "the coord proxy must read row.idempotencyKey"
grep -qx "import './onboard.css';" "$MAIN" && ok || bad "main.js must import onboard.css"
grep -q 'to="/projects/new"' "$FLEET" && ok || bad "Fleet.js must link PROJECTS to /projects/new"
for k in onboarding.product_board_ready onboarding.detect_poll_ms onboarding.detect_poll_max_s; do
  grep -q "('$k'," "$SEED" && ok || bad "the settings fragment must seed $k"
done
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the onboard screen"
else
  ok
fi
node --check "$DRIVE" 2>/dev/null && ok || bad "the drive script does not parse"

# --- 3: the node suite, driven ---------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "onboard-console: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/onboard.bh-7935.test.js 2>&1); then ok
else bad "console-ui/tests/onboard.bh-7935.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "onboard-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
