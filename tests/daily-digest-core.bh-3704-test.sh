#!/bin/bash
# tests/daily-digest-core.bh-3704-test.sh — the daily-digest core sections
# (BH-3704, slice 2 of BH-3688).
#
# The reads are proved by node --test in
# worker/jobs/test/daily-digest-core.bh-3704.test.js, through worker.fetch on a
# real schema.sql. This file names both sources by path so the orphan ratchet
# can see them, drives the pure half with node, and runs the node suite when
# its runtime is there (the daily-digest-contract.bh-3703 pattern).
#
#   C1. both sources exist; core-sections.js no longer says it is a stub.
#   C2. isHumanActor: an @ address is human, the watchdog never is.
#   C3. the node suite, run for real.
# Run from anywhere: tests/daily-digest-core.bh-3704-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PURE="$DIR/worker/jobs/src/lib/daily-digest/core-pure.js"
CORE="$DIR/worker/jobs/src/lib/daily-digest/core-sections.js"

# --- C1: the sources ---------------------------------------------------------
for f in "$PURE" "$CORE"; do [ -f "$f" ] && ok || bad "missing $f"; done
if grep -qiE 'stub|not built' "$CORE"; then bad "core-sections.js still describes itself as a stub"; else ok; fi

# --- C2 / C3: node ----------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "daily-digest-core: node checks SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "daily-digest-core: node checks SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
else
  GOT=$(cd "$T" && node --input-type=module -e '
    const { isHumanActor } = await import(process.argv[1]);
    console.log([isHumanActor("Operator@example.com", []), isHumanActor("jobs-watchdog", ["jobs-watchdog"]),
                 isHumanActor("operator", []), isHumanActor(" operator ", ["OPERATOR"])].join(","));
  ' "file://$PURE" 2>&1)
  [ "$GOT" = "true,false,false,true" ] && ok || bad "isHumanActor answered [$GOT], want [true,false,false,true]"
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/daily-digest-core.bh-3704.test.js 2>&1); then ok
  else bad "node suite failed:"; printf '%s\n' "$NOUT" | grep -E '^\s*not ok|Error|expected|actual' | head -30
  fi
fi

echo "daily-digest-core: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
