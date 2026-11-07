#!/bin/bash
# tests/pool-wake-poll.bh-9074-test.sh — BH-9074 (BH-9067.2, parent T12): the
# pool dispatcher on queue depth. The REAL bin/pool-wake-poll.sh is driven over
# real curl against the REAL jobs worker (tests/lib/wakes-worker.bh-9074.mjs:
# worker/jobs/src/index.js on node:sqlite). Stubbed: bin/fly-dispatch.sh and
# bin/fly-pool-tick.sh in the scratch bin (each start appends one epoch line to
# $T/started.<name>). A `curl` on PATH passes 127.0.0.1 through to the real
# curl and logs any other host to $T/net.log (P9: 0 vendor calls).
#
#   P1  a build-queue row written at t=0, POOL_WAKE_POLL_S=10, window 12:
#       `launched wake=<id>`, both fakes start within 12 s, cursor = id
#   P1b two new rows: one launch (rows=2), cursor = the larger id
#   P2  only a row with id = cursor: no launch, cursor unchanged
#   P2b a worker answer that returns the id = cursor row anyway: no launch
#   P3  a harness/lanes row (real route filter): no launch
#   P3b a mis-filtered answer with a harness/lanes row: no launch, cursor moves past it
#   P4  row pool_wake_poll_s=5, window 6: two GETs; value abc: one GET, one line
#   P5  fly-pool-tick.sh not executable: no `launched`, one `launch-failed`,
#       cursor unchanged; after chmod +x the next run launches
#   P6  worker down: one `read-failed` line, cursor unchanged, exit 0
#   P7  no cursor and 3 history rows, limit 2: seeded, pages=2, no launch; a
#       junk cursor seeds too
#   P8  the 190 and 240 backstop fragments still exist with their lines; the
#       241 line is lease-gated under flock -n locks/pool-wake-poll.lock
#   P9  0 calls to any host but the fake worker
#   P10 flags/lane-off-pool-wake-poll: no GET, no launch
#   P11 the registry declares the three knobs with defaults 10, 55, 100
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-wake-poll.bh-9074-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports the git-ignored catalogs (lanes.json, llm-sites.json).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/wakes-worker.bh-9074.mjs"
SCRIPT_REL=bin/pool-wake-poll.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, curl or setsid missing"; exit 0; }

export LANE_REGISTRY
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT

# The curl guard: the fake worker on 127.0.0.1 goes to the real curl, any other
# host is a vendor call (P9) and fails.
REAL_CURL=$(command -v curl)
mkdir -p "$T/netbin"
cat > "$T/netbin/curl" <<SH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in http://127.0.0.1:*) exec "$REAL_CURL" "\$@" ;; http://*|https://*) printf 'curl %s\n' "\$a" >> "$T/net.log"; exit 7 ;; esac
done
exec "$REAL_CURL" "\$@"
SH
chmod +x "$T/netbin/curl"
: > "$T/net.log"

# fresh — a new scratch harness H and a new worker; exports JOBS_URL.
N=0
fresh() {
  N=$((N+1))
  H="$T/h$N"
  mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
  local s
  # The fakes go in first: scratch_install_closure never overwrites a file.
  for s in fly-dispatch fly-pool-tick; do
    cat > "$H/bin/$s.sh" <<STUB
#!/bin/bash
# stub: one epoch line per start
date +%s.%N >> "$T/started.$N.$s"
STUB
    chmod +x "$H/bin/$s.sh"
  done
  ( cd "$DIR" && scratch_install_closure "$SCRIPT_REL" "$H" && scratch_install_closure bin/jobs-client.sh "$H" ) \
    >/dev/null 2>&1 || bad "setup: closure install of $SCRIPT_REL"
  chmod +x "$H/bin/"*.sh 2>/dev/null
  : > "$T/w$N.log"; : > "$T/w$N.port"
  export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 \
    JOBS_OVERLOAD_RETRIES=0 LANE_GATE_CACHE_S=0 BOX_NAME=hub PATH="$T/netbin:$PATH"
  # Fast defaults: one poll at t=0, one at t=1.
  export POOL_WAKE_POLL_S=1 POOL_WAKE_POLL_WINDOW_S=1
  unset POOL_WAKE_POLL_LIMIT LANE_SINGLE_RUN LANE_GATE_RUN
  node "$SRV" "$T/w$N.log" > "$T/w$N.port" 2> "$T/w$N.err" &
  WPID=$!; PIDS+=("$WPID")
  for _ in $(seq 1 200); do [ -s "$T/w$N.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$N.port")
  if [ -z "$PORT" ]; then wait "$WPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/w$N.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}

LOGF() { printf '%s' "$H/logs/pool-wake-poll.log"; }
cnt() { local c; c=$(grep -cF -- "$1" "$(LOGF)" 2>/dev/null); printf '%s' "${c:-0}"; }
cursor() { cat "$H/state/pool-wake-poll/cursor" 2>/dev/null; }
setcursor() { mkdir -p "$H/state/pool-wake-poll"; printf '%s\n' "$1" > "$H/state/pool-wake-poll/cursor"; }
wake() { curl -s -X PUT "$JOBS_URL/__wake" -d "{\"repo\":\"$1\",\"kind\":\"${2:-queue}\",\"key\":\"${3:-k$N}\"}" | jq -r .id; }
answer() { curl -s -X PUT "$JOBS_URL/__answer" -d "{\"path\":\"/api/wakes\",\"status\":200,\"body\":$1}" >/dev/null; }
setting() { curl -s -X PUT "$JOBS_URL/__setting" -d "{\"key\":\"$1\",\"value\":\"$2\"}" >/dev/null; }
gets() { local c; c=$(grep -c '^GET /api/wakes?repo=harness%2Fbuild-queue&since=' "$T/w$N.log" 2>/dev/null); printf '%s' "${c:-0}"; }
started() { local c; c=$(grep -c . "$T/started.$N.$1" 2>/dev/null); printf '%s' "${c:-0}"; }
# settle — wait (<= 3 s) until a detached fake that the lane reported launching
# has written its line.
settle() {
  local i
  for i in $(seq 1 60); do
    [ "$(started fly-dispatch)" -ge "${1:-1}" ] && [ "$(started fly-pool-tick)" -ge "${1:-1}" ] && return 0
    sleep 0.05
  done
}
run() { "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?; }

echo "P1 a queue row at t=0 is launched within POOL_WAKE_POLL_S+2 s"
fresh; setcursor 0
export POOL_WAKE_POLL_S=10 POOL_WAKE_POLL_WINDOW_S=12
"$H/$SCRIPT_REL" > "$T/run.out" 2>&1 &
RUNPID=$!
T_IN=$(date +%s.%N)
ID=$(wake harness/build-queue queue P1)
wait "$RUNPID"; RC=$?
settle
eq "P1 exit 0" "$RC" 0
eq "P1 one launched line names the row" "$(cnt "pool-wake-poll launched wake=$ID ")" 1
for s in fly-dispatch fly-pool-tick; do
  eq "P1 $s started once" "$(started $s)" 1
  D=$(awk -v a="$T_IN" -v b="$(head -1 "$T/started.$N.$s" 2>/dev/null || echo 9999999999)" 'BEGIN{print (b - a < 12) ? "yes" : "no:" (b - a)}')
  eq "P1 $s started within 12 s of the row" "$D" yes
done
eq "P1 cursor = the row id" "$(cursor)" "$ID"

echo "P1b two new rows: one launch, the cursor at the larger id"
fresh; setcursor 0
A=$(wake harness/build-queue queue P1b-a); B=$(wake harness/build-queue queue P1b-b)
run; settle
eq "P1b exit 0" "$RC" 0
eq "P1b one launched line, rows=2" "$(cnt "pool-wake-poll launched wake=$A rows=2")" 1
eq "P1b fly-pool-tick started once" "$(started fly-pool-tick)" 1
eq "P1b cursor = the larger id" "$(cursor)" "$B"

echo "P2 a row with id = cursor does nothing"
fresh
ID=$(wake harness/build-queue queue P2); setcursor "$ID"
run; sleep 0.3
eq "P2 exit 0" "$RC" 0
eq "P2 no launched line" "$(cnt launched)" 0
eq "P2 no fake started" "$(started fly-pool-tick)$(started fly-dispatch)" 00
eq "P2 cursor unchanged" "$(cursor)" "$ID"
eq "P2 the lane did read (two polls)" "$(gets)" 2
answer "{\"wakes\":[{\"id\":$ID,\"repo\":\"harness/build-queue\",\"kind\":\"queue\"}]}"
run; sleep 0.3
eq "P2b a returned id = cursor row is not new: no launch" "$(cnt launched)" 0
eq "P2b cursor unchanged" "$(cursor)" "$ID"

echo "P3 a harness/lanes row does nothing"
fresh; setcursor 0
L=$(wake harness/lanes lane pm-groom:project-3)
run; sleep 0.3
eq "P3 no launched line" "$(cnt launched)" 0
eq "P3 no fake started" "$(started fly-pool-tick)" 0
eq "P3 cursor unchanged (the route filtered the row)" "$(cursor)" 0
answer "{\"wakes\":[{\"id\":$((L + 6)),\"repo\":\"harness/lanes\",\"kind\":\"lane\"}]}"
run; sleep 0.3
eq "P3b a mis-filtered harness/lanes row: no launch" "$(cnt launched)" 0
eq "P3b the cursor moves past it" "$(cursor)" "$((L + 6))"

echo "P4 the poll period knob: a row of 5 is used, junk falls to 10"
fresh; setcursor 0
setting lane.pool-wake-poll.pool_wake_poll_s 5
unset POOL_WAKE_POLL_S; export POOL_WAKE_POLL_WINDOW_S=6
S0=$(date +%s); run; S1=$(date +%s)
eq "P4 row 5, window 6: two GETs (t=0 and t=5)" "$(gets)" 2
eq "P4 the run took the 5 s period" "$(( S1 - S0 >= 5 && S1 - S0 <= 8 ))" 1
fresh; setcursor 0
export POOL_WAKE_POLL_S=abc POOL_WAKE_POLL_WINDOW_S=6
run
eq "P4 junk: one GET (10 s does not fit a 6 s window)" "$(gets)" 1
eq "P4 junk: exactly one line" "$(cnt "pool-wake-poll POOL_WAKE_POLL_S='abc' is not a whole number 1..60 — using 10")" 1
eq "P4 junk: exit 0" "$RC" 0

echo "P5 a fly lane that cannot start: no launched line, the cursor stays"
fresh; setcursor 0
chmod -x "$H/bin/fly-pool-tick.sh"
ID=$(wake harness/build-queue queue P5)
run; sleep 0.3
eq "P5 exit 0" "$RC" 0
eq "P5 no launched line" "$(cnt launched)" 0
eq "P5 one launch-failed line" "$(cnt "pool-wake-poll launch-failed wake=$ID (fly-pool-tick.sh not executable)")" 1
eq "P5 fly-dispatch not started either" "$(started fly-dispatch)" 0
eq "P5 cursor unchanged" "$(cursor)" 0
chmod +x "$H/bin/fly-pool-tick.sh"
run; settle
eq "P5 after chmod +x the next run launches" "$(cnt "pool-wake-poll launched wake=$ID ")" 1
eq "P5 cursor moved" "$(cursor)" "$ID"

echo "P6 worker down: read-failed, cursor unchanged"
fresh; setcursor 5
export JOBS_URL=http://127.0.0.1:9
run
eq "P6 exit 0" "$RC" 0
eq "P6 one read-failed line per run" "$(cnt "pool-wake-poll read-failed")" 1
eq "P6 cursor unchanged" "$(cursor)" 5
eq "P6 no launch" "$(cnt launched)" 0

echo "P7 a first run seeds the cursor and launches nothing"
fresh
wake harness/build-queue queue P7a >/dev/null; wake harness/build-queue queue P7b >/dev/null
C=$(wake harness/build-queue queue P7c)
export POOL_WAKE_POLL_LIMIT=2
run; sleep 0.3
eq "P7 exit 0" "$RC" 0
eq "P7 seeded line" "$(cnt "pool-wake-poll seeded cursor=$C pages=2")" 1
eq "P7 cursor = the last history id" "$(cursor)" "$C"
eq "P7 no fake started" "$(started fly-pool-tick)$(started fly-dispatch)" 00
eq "P7 no launched line" "$(cnt launched)" 0
run; sleep 0.3
eq "P7 the next run: still no launch" "$(cnt launched)" 0
setcursor junk
run; sleep 0.3
eq "P7 a junk cursor seeds again, no launch" "$(cnt "pool-wake-poll seeded cursor=$C ")$(cnt launched)" 20

echo "P8 the backstop fragments stay; the new line is gated"
eq "P8 190 line" "$(grep -v '^#' "$DIR/cron/lanes/190-fly-dispatch.cron" | grep -c .)/$(grep -c '^\*/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/fly-dispatch.sh$' "$DIR/cron/lanes/190-fly-dispatch.cron")" 1/1
eq "P8 240 line" "$(grep -v '^#' "$DIR/cron/lanes/240-fly-pool-tick.cron" | grep -c .)/$(grep -c '^\*/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/fly-pool-tick.sh$' "$DIR/cron/lanes/240-fly-pool-tick.cron")" 1/1
F241="$DIR/cron/lanes/241-pool-wake-poll.cron"
eq "P8 241 has one active line" "$(grep -v '^#' "$F241" 2>/dev/null | grep -c .)" 1
eq "P8 241 is lease-gated under flock -n" \
  "$(grep -v '^#' "$F241" 2>/dev/null | grep -c '^\* \* \* \* \* /root/harness/bin/hub-lease.sh check && flock -n /root/harness/locks/pool-wake-poll.lock /root/harness/bin/pool-wake-poll.sh ')" 1
eq "P8 241 is a hub lane" "$(grep -cx '# @hub-lanes' "$F241" 2>/dev/null)" 1

echo "P10 the lane switch stops it"
fresh; setcursor 0
touch "$H/flags/lane-off-pool-wake-poll"
wake harness/build-queue queue P10 >/dev/null
run; sleep 0.3
eq "P10 exit 0" "$RC" 0
eq "P10 no GET" "$(gets)" 0
eq "P10 no launch" "$(started fly-pool-tick)" 0

echo "P11 the registry declares the knobs"
eq "P11 knob defaults" "$(jq -c '[.lanes[] | select(.id=="pool-wake-poll") | .knobs[] | select(.env|startswith("POOL_WAKE_POLL")) | [.env, .default]] | sort' "$LANE_REGISTRY")" \
  '[["POOL_WAKE_POLL_LIMIT",100],["POOL_WAKE_POLL_S",10],["POOL_WAKE_POLL_WINDOW_S",55]]'

echo "P9 budget: 0 vendor calls"
eq "P9 net.log is empty ($(head -3 "$T/net.log"))" "$(grep -c . "$T/net.log")" 0

echo "pool-wake-poll: $PASS passed, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
