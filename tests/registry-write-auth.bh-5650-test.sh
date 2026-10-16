#!/bin/bash
# tests/registry-write-auth.bh-5650-test.sh — BH-5650: a registry write
# without the admin token is refused and writes no audit row. Driven through
# bin/registry.sh and the REAL harness-jobs worker
# (tests/lib/registry-fixture-curl.bh-5650.mjs over SQLite).
#
#   U1 a wrong REGISTRY_ADMIN_TOKEN: add-box is rc 1, stderr names 403, no
#      audit row and no box row
#   U2 REGISTRY_ADMIN_TOKEN unset: rc 2 and no curl call at all; show (a read)
#      still works with the bearer alone
#   U3 move-project and drain-box with a wrong token: rc 1, 403, no audit row
#   U4 non-vacuity: the same add-box with the right token writes
#   W  worker/jobs/test/registry-write.bh-5650.test.js passes (W9 is every
#      write route's 401/403 path)
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
CLI="$DIR/bin/registry.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }
audit_n() { rfx_q 'SELECT COUNT(*) AS n FROM registry_audit' | jq '.[0].n'; }
box_n() { rfx_q "SELECT COUNT(*) AS n FROM registry_boxes WHERE box='box-x'" | jq '.[0].n'; }
A0=$(audit_n)

# ---- U1 ----------------------------------------------------------------------
ERR=$(REGISTRY_ADMIN_TOKEN=wrong-fixture-token rfx_db "$CLI" add-box box-x --ip 192.0.2.13 --like project-6 2>&1 >/dev/null); R=$?
[ "$R" = 1 ] && ok || bad "U1 rc $R, want 1"
[[ "$ERR" == *http=403* ]] && ok || bad "U1 stderr does not name 403: $ERR"
[ "$(audit_n)" = "$A0" ] && ok || bad "U1 audit rows were written"
[ "$(box_n)" = 0 ] && ok || bad "U1 a box row was written"
[ "$(rfx_calls)" = 1 ] && ok || bad "U1 made $(rfx_calls) calls, want 1: $(cat "$T/curl.log")"

# ---- U2 ----------------------------------------------------------------------
: > "$T/curl.log"
ERR=$(rfx_db env -u REGISTRY_ADMIN_TOKEN "$CLI" add-box box-x --ip 192.0.2.13 --like project-6 2>&1 >/dev/null); R=$?
[ "$R" = 2 ] && ok || bad "U2 rc $R, want 2"
[[ "$ERR" == *REGISTRY_ADMIN_TOKEN* ]] && ok || bad "U2 stderr does not name the token: $ERR"
[ "$(rfx_calls)" = 0 ] && ok || bad "U2 made $(rfx_calls) curl calls, want 0"
OUT=$(rfx_db env -u REGISTRY_ADMIN_TOKEN "$CLI" show 2>&1); R=$?
[ "$R" = 0 ] && [[ "$OUT" == "registry: version=1 "* ]] && ok || bad "U2 show without the admin token: rc $R '$(head -1 <<<"$OUT")'"

# ---- U3 ----------------------------------------------------------------------
for CMD in "move-project project-1 --box box-small" "drain-box box-small"; do
  # shellcheck disable=SC2086 # the verb and its args split on purpose
  ERR=$(REGISTRY_ADMIN_TOKEN=wrong-fixture-token rfx_db "$CLI" $CMD 2>&1 >/dev/null); R=$?
  [ "$R" = 1 ] && [[ "$ERR" == *http=403* ]] && ok || bad "U3 $CMD: rc $R '$ERR'"
done
[ "$(audit_n)" = "$A0" ] && ok || bad "U3 audit rows were written"

# ---- U4 ----------------------------------------------------------------------
rfx_db "$CLI" add-box box-x --ip 192.0.2.13 --like project-6 >/dev/null 2>&1; R=$?
[ "$R" = 0 ] && [ "$(box_n)" = 1 ] && [ "$(audit_n)" -gt "$A0" ] && ok || bad "U4 the right token did not write (rc $R)"

# ---- W the worker routes themselves -----------------------------------------
# The node suite drives every write route's 401/403 path (W9) through the
# worker's own fetch handler; this runs it so the shell suite owns the source.
WROUTES="$DIR/worker/jobs/src/routes/registry-write.js"
[ -f "$WROUTES" ] && ok || bad "W $WROUTES is missing"
if (cd "$DIR/worker/jobs" && node --test test/registry-write.bh-5650.test.js) > "$T/node.out" 2>&1; then ok
else bad "W node --test worker/jobs/test/registry-write.bh-5650.test.js failed: $(grep -m3 '^not ok' "$T/node.out")"; fi

echo "registry-write-auth: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
