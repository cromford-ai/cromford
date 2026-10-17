#!/bin/bash
# tests/docker-pool.bh-7300-test.sh — BH-7300 (slice C0): the docker-pool claim
# lease. bin/lib/docker-pool.sh and the sweep block in bin/jobs-watchdog.sh,
# driven over real curl against the REAL jobs worker
# (tests/lib/docker-pool-worker.bh-7300.mjs) on node:sqlite with the composed
# schema, so worker/jobs/src/routes/docker-pool.js answers every request.
#
#   D1  docker_pool_claim rc 0 prints the TSV; heartbeat rc 0 prints
#       lease_until; release queued rc 0 and the row is queued again
#   D2  two runners race for one key: exactly one rc 0, one rc 9; then the hub
#       pool's keyed queue_claim of that row answers rc 2 (AT1)
#   D3  max 0: rc 9, `off` on stderr, no lease (AT4)
#   D4  worker down: rc 1 and no TSV; a missing argument: rc 1, no request
#   D5  a 409 with no reason and a 200 with no fields are rc 1; key not
#       queued is rc 2; release done rc 0 prints 0
#   W1  bin/jobs-watchdog.sh with no expired lease: log line
#       `docker-pool: 0 lease(s) expired, 0 row(s) requeued`, no ALERTS line
#   W2  one lease expired: the row is queued, exactly one DOCKER POOL LEASE
#       EXPIRED line; a second run adds no line and the row stays queued (AT2)
#   W3  the sweep answers 500: one log line, no ALERTS line, exit 0
#
# A lease expires through the fixture's /__expire hook, never by waiting.
# The node suite worker/jobs/test/docker-pool.bh-7300.test.js holds the route
# decision rules; this suite runs it when node:sqlite is there.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/docker-pool.bh-7300-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/docker-pool-worker.bh-7300.mjs"
LIB="$DIR/bin/lib/docker-pool.sh"
ROUTE="$DIR/worker/jobs/src/routes/docker-pool.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
[ -f "$LIB" ] || bad "setup: $LIB missing"
[ -f "$ROUTE" ] || bad "setup: $ROUTE missing"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/locks"
: > "$H/env/global.env"
for L in bin/jobs-client.sh bin/lib/docker-pool.sh bin/jobs-watchdog.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10

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
trap 'kill "$SPID" 2>/dev/null' EXIT

enqueue() { curl -sS -X POST -d "$(jq -nc --arg p "$1" --arg k "$2" --arg g "${3:-fly}" '{project:$p,key:$k,target:$g}')" "$JOBS_URL/__enqueue" > /dev/null; }
row() { curl -sS "$JOBS_URL/__row?project=$1&key=$2"; }
leases() { curl -sS "$JOBS_URL/__leases?project=$1&key=$2"; }
expire() { curl -sS -X POST -d "{\"project\":\"$1\",\"key\":\"$2\"}" "$JOBS_URL/__expire" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
LIBS=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/docker-pool.sh'"
# lib <box> <shell code> — runs the code with the client and the lib sourced
# as box <box>; stdout to $T/out, stderr to $T/err, the code's rc returned.
lib() { JOBS_BOX="$1" bash -c "$LIBS && $2" > "$T/out" 2> "$T/err"; }

# ============================================================================
echo "D1: claim, heartbeat and release queued through the lib"
setting docker_pool.max_concurrent 2
enqueue p1 D-1
lib mac-a 'docker_pool_claim p1 D-1'; RC=$?
IFS=$'\t' read -r K TID ATT UNTIL < "$T/out"
[ "$RC" = 0 ] && [ "$K" = D-1 ] && [ "$TID" = id-D-1 ] && [ "$ATT" = 0 ] && [[ $UNTIL =~ ^20[0-9-]+T[0-9:]+Z$ ]] \
  && ok "D1 claim rc 0 prints key ticket_id attempt lease_until" || bad "D1 claim rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
[ "$(row p1 D-1 | jq -r .claimed_by)" = mac-a ] && ok "D1 the row is claimed by mac-a" || bad "D1 row: $(row p1 D-1)"
lib mac-a 'docker_pool_heartbeat p1 D-1'; RC=$?
[ "$RC" = 0 ] && [[ $(cat "$T/out") =~ ^20[0-9-]+T[0-9:]+Z$ ]] && ok "D1 heartbeat rc 0 prints lease_until" || bad "D1 heartbeat rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
lib mac-a 'docker_pool_release p1 D-1 queued "SIGTERM hand-off"'; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 1 ] && ok "D1 release queued rc 0 prints 1" || bad "D1 release rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
R=$(row p1 D-1)
[ "$(jq -r .status <<<"$R")" = queued ] && [ "$(jq -r .claimed_by <<<"$R")" = null ] && ok "D1 the row is queued with no claimant" || bad "D1 row after release: $R"
[ "$(leases p1 D-1 | jq -r '.[0].status')" = released ] && ok "D1 the lease ended released" || bad "D1 lease: $(leases p1 D-1)"
lib mac-a 'docker_pool_heartbeat p1 D-1'; RC=$?
[ "$RC" = 9 ] && grep -q 'no_lease' "$T/err" && [ ! -s "$T/out" ] && ok "D1 a heartbeat after release: rc 9, no_lease" || bad "D1 late heartbeat rc=$RC err=$(cat "$T/err")"

# ============================================================================
echo "D2: two runners race for one row; the hub pool then cannot claim it (AT1)"
setting docker_pool.max_concurrent 1
enqueue p1 D-2
( lib_a() { JOBS_BOX=mac-a bash -c "$LIBS && docker_pool_claim p1 D-2" > "$T/a.out" 2> "$T/a.err"; echo $? > "$T/a.rc"; }
  lib_b() { JOBS_BOX=mac-b bash -c "$LIBS && docker_pool_claim p1 D-2" > "$T/b.out" 2> "$T/b.err"; echo $? > "$T/b.rc"; }
  lib_a & lib_b & wait )
RCS="$(cat "$T/a.rc") $(cat "$T/b.rc")"
case "$RCS" in "0 9"|"9 0") ok "D2 exactly one rc 0 and one rc 9 ($RCS)" ;; *) bad "D2 rcs: $RCS a=$(cat "$T/a.err") b=$(cat "$T/b.err")" ;; esac
grep -q 'lost' "$T/a.err" "$T/b.err" && ok "D2 the loser's stderr says lost" || bad "D2 stderr: $(cat "$T/a.err" "$T/b.err")"
[ "$(leases p1 D-2 | jq 'length')" = 1 ] && ok "D2 one lease" || bad "D2 leases: $(leases p1 D-2)"
WIN=$(row p1 D-2 | jq -r .claimed_by)
lib fly-pool 'queue_claim p1 fly D-2'; RC=$?
[ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok "D2 queue_claim p1 fly D-2: rc 2, nothing claimed" || bad "D2 queue_claim rc=$RC out=$(cat "$T/out")"
[ "$(row p1 D-2 | jq -r .claimed_by)" = "$WIN" ] && [[ $WIN == mac-? ]] && ok "D2 the row stays with $WIN" || bad "D2 row: $(row p1 D-2)"

# ============================================================================
echo "D3: max 0 claims nothing (AT4)"
setting docker_pool.max_concurrent 0
enqueue p1 D-3
lib mac-c 'docker_pool_claim p1 D-3'; RC=$?
[ "$RC" = 9 ] && grep -q 'off' "$T/err" && [ ! -s "$T/out" ] && ok "D3 rc 9, off on stderr, no TSV" || bad "D3 rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
[ "$(leases p1 D-3 | jq 'length')" = 0 ] && [ "$(row p1 D-3 | jq -r .status)" = queued ] && ok "D3 no lease, the row stays queued" || bad "D3 state: $(row p1 D-3) $(leases p1 D-3)"

# ============================================================================
echo "D4: worker down; missing argument"
JOBS_URL=http://127.0.0.1:1 lib mac-a 'docker_pool_claim p1 D-3'; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "D4 worker down: rc 1, no TSV" || bad "D4 down rc=$RC out=$(cat "$T/out")"
JOBS_URL=http://127.0.0.1:1 lib mac-a 'docker_pool_sweep'; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "D4 sweep with worker down: rc 1" || bad "D4 sweep down rc=$RC"
N0=$(wc -l < "$T/srv.log")
lib mac-a 'docker_pool_claim p1'; R1=$?
lib mac-a 'docker_pool_release p1 D-3 failed'; R2=$?
lib mac-a 'JOBS_BOX=; docker_pool_claim p1 D-3'; R3=$?
[ "$R1$R2$R3" = 111 ] && [ "$(wc -l < "$T/srv.log")" = "$N0" ] && ok "D4 a missing key, a bad status, no box: rc 1 and no request" || bad "D4 args: $R1 $R2 $R3"

# ============================================================================
echo "D5: odd answers"
answer '{"status":409,"body":"{\"error\":\"refused\"}"}'
lib mac-a 'docker_pool_claim p1 D-3'; RC=$?
[ "$RC" = 1 ] && ok "D5 a 409 with no reason: rc 1" || bad "D5 409 rc=$RC"
answer '{"status":200,"body":"{\"claimed\":true}"}'
lib mac-a 'docker_pool_claim p1 D-3'; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "D5 a 200 with no queued/lease_until: rc 1, no TSV" || bad "D5 200 rc=$RC out=$(cat "$T/out")"
answer '{}'
setting docker_pool.max_concurrent 2
lib mac-a 'docker_pool_claim p1 NOT-QUEUED'; RC=$?
[ "$RC" = 2 ] && ok "D5 a key that is not queued: rc 2" || bad "D5 404 rc=$RC"
enqueue p1 D-5
lib mac-a 'docker_pool_claim p1 D-5 >/dev/null && docker_pool_release p1 D-5 done'; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 0 ] && [ "$(row p1 D-5 | jq -r .status)" = claimed ] \
  && ok "D5 release done rc 0 prints 0, the row is left claimed" || bad "D5 release done rc=$RC out=$(cat "$T/out") row=$(row p1 D-5)"

# ============================================================================
run_watchdog() { ( export JOBS_BOX=hub-fixture; bash "$H/bin/jobs-watchdog.sh" > "$T/wd.out" 2>&1 ); }
dp_lines() { grep -c 'docker-pool:' "$H/logs/jobs-watchdog.log" 2>/dev/null; }
alerts_dp() { grep -c 'DOCKER POOL LEASE EXPIRED' "$H/logs/ALERTS.log" 2>/dev/null; }

echo "W1: watchdog with no expired lease"
run_watchdog; RC=$?
[ "$RC" = 0 ] && ok "W1 the watchdog exits 0" || bad "W1 rc=$RC $(tail -5 "$T/wd.out")"
grep -q 'docker-pool: 0 lease(s) expired, 0 row(s) requeued' "$H/logs/jobs-watchdog.log" 2>/dev/null \
  && ok "W1 log line: 0 expired, 0 requeued" || bad "W1 log: $(grep docker-pool "$H/logs/jobs-watchdog.log" 2>/dev/null)"
[ "$(alerts_dp)" = 0 ] && ok "W1 no ALERTS line" || bad "W1 alerts: $(cat "$H/logs/ALERTS.log")"

echo "W2: one lease expired: requeued once, one ALERTS line (AT2)"
enqueue p1 W-2
lib mac-w 'docker_pool_claim p1 W-2' || bad "W2 setup claim: $(cat "$T/err")"
expire p1 W-2
run_watchdog
R=$(row p1 W-2)
[ "$(jq -r .status <<<"$R")" = queued ] && [ "$(jq -r .claimed_by <<<"$R")" = null ] && ok "W2 the row is queued with no claimant" || bad "W2 row: $R"
[ "$(alerts_dp)" = 1 ] && grep -q 'DOCKER POOL LEASE EXPIRED: p1/W-2 on mac-w; the row is back on the queue' "$H/logs/ALERTS.log" \
  && ok "W2 exactly one ALERTS line naming p1/W-2 on mac-w" || bad "W2 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'docker-pool: 1 lease(s) expired, 1 row(s) requeued' "$H/logs/jobs-watchdog.log" && ok "W2 log line: 1 expired, 1 requeued" || bad "W2 log: $(grep docker-pool "$H/logs/jobs-watchdog.log")"
run_watchdog
[ "$(alerts_dp)" = 1 ] && ok "W2 a second run adds no ALERTS line" || bad "W2 second run alerts: $(alerts_dp)"
[ "$(row p1 W-2 | jq -r .status)" = queued ] && ok "W2 the row stays queued" || bad "W2 row: $(row p1 W-2)"
[ "$(leases p1 W-2 | jq -r '.[0].status')" = expired ] && ok "W2 the lease ended expired" || bad "W2 lease: $(leases p1 W-2)"

echo "W3: the sweep answers 500"
answer '{"status":500,"body":"{\"error\":\"fixture failure\"}"}'
B=$(dp_lines)
run_watchdog; RC=$?
answer '{}'
[ "$RC" = 0 ] && ok "W3 the watchdog exits 0" || bad "W3 rc=$RC"
[ "$(dp_lines)" = $((B + 1)) ] && grep -q 'docker-pool: sweep failed' "$H/logs/jobs-watchdog.log" && ok "W3 one log line: sweep failed" || bad "W3 log: $(grep docker-pool "$H/logs/jobs-watchdog.log")"
[ "$(alerts_dp)" = 1 ] && ok "W3 no new ALERTS line" || bad "W3 alerts: $(alerts_dp)"

# ============================================================================
echo "N: the route decision rules (node suite)"
if node -e "import('node:sqlite').then(()=>process.exit(0),()=>process.exit(3))" 2>/dev/null; then
  ( cd "$DIR/worker/jobs" && node --test test/docker-pool.bh-7300.test.js > "$T/node.out" 2>&1 ) \
    && ok "N worker/jobs/test/docker-pool.bh-7300.test.js passes" || bad "N node suite: $(grep -E '^not ok|^# fail' "$T/node.out")"
else
  echo "  SKIP N: node:sqlite unavailable"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
