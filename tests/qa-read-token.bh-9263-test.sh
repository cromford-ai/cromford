#!/bin/bash
# tests/qa-read-token.bh-9263-test.sh — BH-9263: a QA preview session reads
# harness-jobs only on the QA allowlist (whoami, jobs, flags), projected, with
# a separate QA_READ_TOKEN; the Pages root middleware checks same-origin on
# cookie writes, sets no-store on /api/*, and lets a valid `dash` win over a
# stale `dashqa`.
#
#   Q0  the sources exist, the two policy copies are byte-identical, and the
#       jobs worker's 401 line asks the QA token
#   Q1  console-ui/tests/qa-read.bh-9263.test.js (policy + coord proxy)
#   Q2  console-ui/tests/middleware.bh-9263.test.js (the middleware)
#   Q3  worker/jobs/test/qa-read-token.bh-9263.test.js (the REAL worker.fetch)
#
# Run from anywhere: tests/qa-read-token.bh-9263-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node missing"; exit 0; }

# --- Q0 sources -----------------------------------------------------------------
for f in console-ui/functions/_middleware.js console-ui/functions/_lib/qa-read-policy.js \
         "console-ui/functions/api/coord/[[path]].js" worker/jobs/src/lib/qa-read.js \
         worker/jobs/src/lib/qa-read-policy.js console-ui/functions/_lib/qa-read-proxy.js \
         console-ui/tests/qa-read.bh-9263.test.js console-ui/tests/middleware.bh-9263.test.js \
         worker/jobs/test/qa-read-token.bh-9263.test.js; do
  [ -s "$DIR/$f" ] && ok "Q0 source exists: $f" || bad "Q0 missing source $f"
done
cmp -s "$DIR/console-ui/functions/_lib/qa-read-policy.js" "$DIR/worker/jobs/src/lib/qa-read-policy.js" \
  && ok "Q0 the two policy copies are byte-identical" || bad "Q0 worker/jobs/src/lib/qa-read-policy.js differs from console-ui/functions/_lib/qa-read-policy.js"
src=$(cat "$DIR/worker/jobs/src/index.js")
grep -qF 'if (!bearerOk(req, env)) return qaReadOk(req, env) ? qaReadDispatch({ req, env, url, path, t }, ROUTES) : json(401' <<<"$src" \
  && ok "Q0 index.js: a failed bearer asks the QA read token" || bad "Q0 index.js 401 line does not ask qaReadOk"

# --- Q1-Q3 the node suites ------------------------------------------------------
run() { # run <label> <dir> <test file>
  local out rc
  out=$(cd "$DIR/$2" && node --test "$3" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && grep -qE '^# fail 0$' <<<"$out" && grep -qE '^# skipped 0$' <<<"$out"; then ok "$1"
  else bad "$1 (rc=$rc)"; grep -E '^not ok|^# (pass|fail|skipped)' <<<"$out" | sed 's/^/       /'; fi
}
run "Q1 policy and coord proxy" console-ui tests/qa-read.bh-9263.test.js
run "Q2 Pages middleware" console-ui tests/middleware.bh-9263.test.js
run "Q3 jobs worker QA token" worker/jobs test/qa-read-token.bh-9263.test.js

echo "qa-read-token: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
