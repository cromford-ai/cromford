#!/bin/bash
# tests/otp-wait.bh-7732-test.sh — BH-7732: bin/otp-wait.sh, the web-task
# lanes' read of the otp inbox. The REAL script (installed with its source
# closure) polls GET /api/otp over real curl against the REAL jobs worker
# (tests/lib/otp-worker.bh-7732.mjs) on node:sqlite with the composed schema.
#
#   W1  a seeded code row: stdout is exactly the code, exit 0
#   W2  no row, --timeout 3 --interval 1: exit 1, empty stdout, one stderr line
#   W3  a row that lands after the first poll is found on a later poll
#   W4  no file under the scratch harness and no stderr line holds a code
#   W5  no address, a bad --timeout, --since or flag: exit 64, no request;
#       the defaults parse as --timeout 120 --interval 5 --since now-60s
#   W6  the worker refuses the bearer (401): exit 1 at the deadline, no stdout
#
# Fixture codes are visibly fake; every row's address is @otp.example.test.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/otp-wait.bh-7732-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/otp-worker.bh-7732.mjs"
SCRIPT="$DIR/bin/otp-wait.sh"
ROUTE="$DIR/worker/jobs/src/routes/otp.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
[ -f "$SCRIPT" ] || bad "setup: $SCRIPT missing"
[ -f "$ROUTE" ] || bad "setup: $ROUTE missing"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env"
: > "$H/env/global.env"
for L in bin/otp-wait.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
export HARNESS_SECRET=tok-fixture-bh7732
export JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT

seed() { curl -sS -X POST -d "$(jq -nc --arg t "$1" --arg m "$2" --arg c "$3" --arg a "$4" '{to:$t,mid:$m,code:$c,at:$a}')" "$JOBS_URL/__seed" > /dev/null; }
arm() { curl -sS -X POST -d "$(jq -nc --argjson n "$1" --arg t "$2" --arg m "$3" --arg c "$4" --arg a "$5" '{after:$n,row:{to:$t,mid:$m,code:$c,at:$a}}')" "$JOBS_URL/__arm" > /dev/null; }
polls() { grep -c "^GET /api/otp?to=$1&" "$T/srv.log"; }
# run <args...> — the installed script; stdout to $T/out, stderr to $T/err, rc returned.
run() { bash "$H/bin/otp-wait.sh" "$@" > "$T/out" 2> "$T/err"; }
CODES=(731942 KX4Q9Z 805316)

# ============================================================================
echo "W1: a seeded row prints exactly the code"
seed w1@otp.example.test m1 731942 2026-10-20T16:00:00Z
run W1@OTP.example.test --since 2026-10-20T15:59:00Z --timeout 5 --interval 1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 731942 ] && [ ! -s "$T/err" ] \
  && ok "W1 rc 0, stdout is the code, stderr empty" || bad "W1 rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
[ "$(polls w1%40otp.example.test)" = 1 ] && ok "W1 one poll, the address lowercased and url-encoded" || bad "W1 polls: $(cat "$T/srv.log")"
seed w1b@otp.example.test m2 805316 2026-10-20T16:00:00Z
run w1b@otp.example.test --since 1792511940 --timeout 5 --interval 1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 805316 ] && ok "W1 --since in epoch seconds" || bad "W1 epoch rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"

echo "W2: no row until the deadline"
run w2@otp.example.test --since 2026-10-20T15:59:00Z --timeout 3 --interval 1; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "W2 rc 1, empty stdout" || bad "W2 rc=$RC out=$(cat "$T/out")"
[ "$(wc -l < "$T/err")" = 1 ] && grep -qx 'otp-wait: no code for w2@otp.example.test since 2026-10-20T15:59:00Z after 3s' "$T/err" \
  && ok "W2 exactly one stderr line" || bad "W2 err: $(cat "$T/err")"
N=$(polls w2%40otp.example.test)
[ "$N" -ge 2 ] && [ "$N" -le 5 ] && ok "W2 polled $N times in 3 s at a 1 s interval" || bad "W2 polls=$N"

echo "W3: a row that lands after the first poll"
arm 1 w3@otp.example.test m3 KX4Q9Z 2026-10-20T16:01:00Z
run w3@otp.example.test --since 2026-10-20T15:59:00Z --timeout 10 --interval 1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = KX4Q9Z ] && [ "$(polls w3%40otp.example.test)" = 2 ] \
  && ok "W3 found on the second poll" || bad "W3 rc=$RC out=$(cat "$T/out") polls=$(polls w3%40otp.example.test) err=$(cat "$T/err")"

echo "W6: a wrong bearer"
HARNESS_SECRET=tok-fixture-wrong run w1@otp.example.test --since 2026-10-20T15:59:00Z --timeout 2 --interval 1; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && grep -q '^otp-wait: no code for w1@otp.example.test ' "$T/err" \
  && ok "W6 401: rc 1, no stdout" || bad "W6 rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
grep -q 'GET /api/otp?to=w1%40otp.example.test&since=2026-10-20T15:59:00Z 401' "$T/srv.log" && ok "W6 the worker answered 401" || bad "W6 log: $(tail -3 "$T/srv.log")"

echo "W4: no log file and no stderr line holds a code"
LEAK=""
for c in "${CODES[@]}"; do
  grep -rl -- "$c" "$H" 2>/dev/null | grep -q . && LEAK="$LEAK $c(file)"
  grep -q -- "$c" "$T/err" && LEAK="$LEAK $c(stderr)"
done
[ -z "$LEAK" ] && ok "W4 no code under the scratch harness or on stderr" || bad "W4 leaked:$LEAK"
[ -s "$H/logs/jobs-client.log" ] && ok "W4 the client did write its log (the 401), and it holds no code" || bad "W4 expected a jobs-client.log line from W6"

echo "W5: arguments"
BEFORE=$(wc -l < "$T/srv.log")
for args in "" "--timeout 5" "w5@otp.example.test --timeout abc" "w5@otp.example.test --interval 0" \
            "w5@otp.example.test --since yesterday" "w5@otp.example.test --bogus" "w5@otp.example.test extra" "not-an-address"; do
  # shellcheck disable=SC2086
  run $args; RC=$?
  [ "$RC" = 64 ] && grep -q '^usage: otp-wait.sh' "$T/err" && [ ! -s "$T/out" ] && ok "W5 [$args] exit 64 with usage" || bad "W5 [$args] rc=$RC err=$(cat "$T/err")"
done
[ "$(wc -l < "$T/srv.log")" = "$BEFORE" ] && ok "W5 no request on a usage error" || bad "W5 a usage error sent a request"
OTP_WAIT_DRYRUN_ARGS=1 OTP_WAIT_NOW=1792512000 run W5@otp.example.test; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 'to=w5@otp.example.test timeout=120 interval=5 since=2026-10-20T15:59:00Z' ] \
  && ok "W5 defaults: timeout 120, interval 5, since now-60s" || bad "W5 defaults rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
OTP_WAIT_DRYRUN_ARGS=1 run w5@otp.example.test --timeout 30 --interval 2 --since 1792511940; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 'to=w5@otp.example.test timeout=30 interval=2 since=1792511940' ] \
  && ok "W5 explicit flags" || bad "W5 flags rc=$RC out=$(cat "$T/out")"
[ "$(wc -l < "$T/srv.log")" = "$BEFORE" ] && ok "W5 a dry run sends no request" || bad "W5 a dry run sent a request"

echo "otp-wait.bh-7732: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
