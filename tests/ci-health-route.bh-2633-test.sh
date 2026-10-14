#!/bin/bash
# tests/ci-health-route.bh-2633-test.sh — the harness-jobs route
# PUT/GET /api/ci-health (BH-2633, slice BH-2517.2).
#
# WHY A SHELL SUITE AS WELL. The route's behaviour is proved by node --test in
# worker/jobs/test/routes/ci-health.bh-2633.test.js (real worker.fetch over the
# real schema.sql in node:sqlite). What this file adds is what the impact lane
# and the orphan ratchet can SEE:
#   1. it names the route module by path, and the module is registered in
#      worker/jobs/src/index.js;
#   2. no line of the module builds SQL from a template literal;
#   3. it runs the node suite for real when node >= 22 (node:sqlite) is here.
# The box side (the two lanes that push) is tests/ci-health-push.bh-2633-test.sh.
# Run from anywhere: tests/ci-health-route.bh-2633-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/ci-health.js"
INDEX="$DIR/worker/jobs/src/index.js"
NODE_TEST="$DIR/worker/jobs/test/routes/ci-health.bh-2633.test.js"

# --- 1: the module exists and is registered ---------------------------------
if [ -f "$ROUTE" ]; then ok; else bad "missing $ROUTE"; fi
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-ci-health.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "ci-health has no route-table.d fragment (BH-4607: the fragment IS the registration)"
grep -q 'from "./routes/ci-health.js"' "$INDEX" && bad "index.js hand-registers ci-health: the fragment registers it (BH-4607)" || ok

# --- 2: no template-literal SQL ---------------------------------------------
# A missing file must fail here too, not pass as "no hits" (D3).
if [ -f "$ROUTE" ]; then
  HITS=$(grep -nE '(SELECT|INSERT|UPDATE|DELETE|LIMIT|WHERE).*\$\{|\$\{.*(SELECT|INSERT|UPDATE|DELETE|LIMIT|WHERE)' "$ROUTE")
  [ -z "$HITS" ] && ok || bad "template-literal SQL in the route: $HITS"
else
  bad "no route module to scan for template-literal SQL"
fi

# --- 3: the node suite --------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ci-health-route: node suite SKIPPED — node is not installed on this box"
elif [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "ci-health-route: node suite SKIPPED — node < 22 has no node:sqlite"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
else
  OUT=$(cd "$DIR/worker/jobs" && node --test "$NODE_TEST" 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "node suite rc=$RC"; printf '%s\n' "$OUT" | grep -E '^not ok|error:' | head -20; fi
fi

echo "ci-health-route: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
