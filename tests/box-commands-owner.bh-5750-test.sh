#!/bin/bash
# tests/box-commands-owner.bh-5750-test.sh — the C1 plumbing of the Mission
# Control box controls (BH-5750): one type list, the owner gate and the price
# token.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by the node suites below,
# run through the real worker.fetch on real SQLite. This file names the new
# sources by path so the orphan ratchet and the impact lane can see them, drives
# the pure half for real, and runs the node suites.
#   1. lib/box-command-types.js and lib/box-command-args.js, driven: the owner
#      match trims and lower-cases, an unset owner list is nobody, the price is
#      the FIRST price line, a launch with no usd_mo has no figure.
#   2. the node suites: worker/jobs/test/box-commands-{v2,owner,quote}.bh-5750,
#      box-command-types-drift.bh-5750, and console-ui/tests/box-commands-orgo
#      .bh-5750 when the console-ui dependencies are installed.
# Run from anywhere: tests/box-commands-owner.bh-5750-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports catalog/lanes.json and catalog/llm-sites.json, both
# generated and git-ignored: render them first (as box-commands-worker.bh-2518).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TYPES_JS="$DIR/worker/jobs/src/lib/box-command-types.js"
ARGS_JS="$DIR/worker/jobs/src/lib/box-command-args.js"
FRAG="$DIR/worker/jobs/schema.d/0014-bh-5750-box-commands-v2.sql"
for f in "$TYPES_JS" "$ARGS_JS" "$FRAG"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "box-commands-owner: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the libs, driven ----------------------------------------------------
OUT=$(node --input-type=module -e "
import { TYPES, OWNER_ONLY } from '$TYPES_JS';
import { isOwner, quoteFigure } from '$ARGS_JS';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('types', TYPES.length, 14);
eq('owner-only', OWNER_ONLY.size, 9);
eq('owner-case', isOwner({ BOX_OPS_OWNERS: ' A@EXAMPLE.COM ' }, 'a@example.com'), true);
eq('owner-lookalike', isOwner({ BOX_OPS_OWNERS: 'a@example.com' }, 'a@example.com.example.net'), false);
eq('owner-unset', isOwner({}, 'a@example.com'), false);
eq('owner-console', isOwner({ BOX_OPS_OWNERS: 'console' }, 'console'), true);
eq('price-first', quoteFigure('orgo_resize_quote', 'PLAN cost +\$12/mo (now) | COST: resize x +\$99/mo'), '12');
eq('price-none-resize', quoteFigure('orgo_resize_quote', 'box-ops: verb=resize result=PLAN'), '0');
eq('price-launch', quoteFigure('orgo_launch_quote', 'box-launch: box=b usd_mo=40 smoke=PENDING'), '40');
eq('price-none-launch', quoteFigure('orgo_launch_quote', 'capacity: pool fits'), null);
" 2>&1)
while IFS= read -r l; do
  case "$l" in ok\ *) ok ;; *) bad "lib: $l" ;; esac
done <<< "$OUT"

# --- 2: the node suites -----------------------------------------------------
for t in box-commands-v2 box-command-types-drift box-commands-owner box-commands-quote; do
  if (cd "$DIR/worker/jobs" && node --test "test/$t.bh-5750.test.js" >/dev/null 2>&1); then ok; else bad "node suite worker/jobs/test/$t.bh-5750.test.js"; fi
done
if [ -d "$DIR/console-ui/node_modules" ]; then
  if (cd "$DIR/console-ui" && node --test tests/box-commands-orgo.bh-5750.test.js >/dev/null 2>&1); then ok; else bad "node suite console-ui/tests/box-commands-orgo.bh-5750.test.js"; fi
else
  echo "box-commands-owner: console-ui/node_modules absent — console suite left to the console-ui CI job"
fi

echo "box-commands-owner.bh-5750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
