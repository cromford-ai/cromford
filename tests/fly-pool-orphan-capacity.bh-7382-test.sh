#!/bin/bash
# tests/fly-pool-orphan-capacity.bh-7382-test.sh — a pool state of 8 orphan
# jobs and 6 machines: the reap releases the 8, and capacity returns to the
# configured limit (BH-7382, acceptance 1).
#
# WHAT THIS PINS. The ticket asked for a reaper for jobs whose Fly machine is
# gone or stopped. The tick already is one: with a usable `machines list`, the
# REAP in bin/fly-pool.sh reads an absent machine as state "" and a `stopped`
# one as stopped, both are deaths (DEAD=1), and the dead path destroys the
# machine, removes the job file, closes the row and requeues the job, all in
# the same tick (tests/fly-orphan-jobs-test.sh §1-§3 pin one job each). Run
# against the project-6-os numbers it releases all 8 and the spawn budget is
# cap - 6. So BH-7382 adds no second reaper; this suite holds the ticket's own
# criterion against a regression.
#   o1  6 started machines with jobs + 8 jobs on machine ids the listing does
#       not return, cap 8, 3 queued: after one tick the 8 job files are gone,
#       the 6 stay, the 8 keys are requeued with one death each, one audit
#       line per release, and the pool line reads running=6 spawning=2 cap=8.
#   o2  .sweep.json reports no orphan job left after that tick.
#   o3  the stopped arm: a job on a `stopped` machine is released the same
#       tick, and the machine is destroyed.
#   o4  near miss: the 6 live machines are never destroyed.
#
# Run from anywhere: tests/fly-pool-orphan-capacity.bh-7382-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY FLY_API_TOKEN FLY_ACCESS_TOKEN \
      POOL_STALL_ALERT_S POOL_UNDERUSE_ALERT_S

H="$T/h"
QD="$H/state/build-queue/tproj"; MD="$H/state/fly-pool/tproj"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" "$MD" "$QD" "$H/builds" "$T/fakebin"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machines list"*) cat "$T/listing.json" 2>/dev/null || echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
FLY
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

FRESH=$(date -u -d "@$(( $(date +%s) - 60 ))" +%Y-%m-%dT%H:%M:%SZ)
reset() {
  local p
  for p in "$QD"/* "$MD"/* "$MD"/.sweep.json "$T/fly-calls" "$T/alert-calls" "$T/listing.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  for p in "$H/flags"/alerted-*; do [ -e "$p" ] && scratch_rm "$p"; done
  : > "$H/logs/fly-pool.log"
  printf '8\n' > "$H/flags/fly-pool-tproj"
  # A health halt stops the tick after the budget line and before any spawn,
  # so the line is read without driving the spawn path.
  : > "$H/flags/pool-halt-tproj"
}
job() { jq -nc --arg m "$1" --arg k "$2" '{machine:$m,key:$k,ticket_id:"7",attempt:0,deferrals:0,deaths:0}' > "$MD/$1.json"; }
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" FLY_API_TOKEN_TPROJ=tok-fixture-proj \
           POOL_INFLIGHT_HOLD_READS=0 "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}

# o1 the project-6-os shape: 6 live, 8 orphans, cap 8, 3 queued.
reset
ROWS=""
for i in 1 2 3 4 5 6; do
  job "m${i}live" "LV-$i"
  ROWS="$ROWS{\"id\":\"m${i}live\",\"state\":\"started\",\"updated_at\":\"$FRESH\"},"
done
for i in 1 2 3 4 5 6 7 8; do job "m${i}gone" "OR-$i"; done
printf '[%s]\n' "${ROWS%,}" > "$T/listing.json"
for i in 1 2 3; do jq -nc --arg k "QD-$i" '{ticket_id:"8",key:$k,attempt:0,deferrals:0,deaths:0}' > "$QD/QD-$i.json"; done
tick
N=$(ls "$MD"/m*gone.json 2>/dev/null | wc -l)
[ "$N" = 0 ] && ok || bad "o1: the 8 orphan job files must be released (left: $N)"
[ "$(ls "$MD"/m*live.json 2>/dev/null | wc -l)" = 6 ] && ok || bad "o1: the 6 live job files must stay: $(ls "$MD")"
REQ=0
for i in 1 2 3 4 5 6 7 8; do
  [ "$(jq -r '.deaths' "$QD/OR-$i.json" 2>/dev/null)" = 1 ] && REQ=$((REQ + 1))
done
[ "$REQ" = 8 ] && ok || bad "o1: the 8 keys must be requeued with deaths=1 ($REQ were): $(ls "$QD")"
[ "$(grep -c 'machine m[1-8]gone for OR-[1-8] dead (state=gone)' "$H/logs/fly-pool.log")" = 8 ] && ok \
  || bad "o1: one audit line per release: $(grep -c 'dead (state=' "$H/logs/fly-pool.log")"
grep -q 'pool tproj: queued=11 running=6 spawning=2 cap=8$' "$H/logs/fly-pool.log" && ok \
  || bad "o1: capacity must return to the limit (running=6 spawning=2 cap=8): $(grep -o 'pool tproj: .*' "$H/logs/fly-pool.log")"
# o2 nothing is left for the sweep to call an orphan.
[ "$(jq -r '.orphan_jobs | length' "$MD/.sweep.json" 2>/dev/null)" = 0 ] && ok \
  || bad "o2: no orphan job may remain after the tick: $(cat "$MD/.sweep.json" 2>/dev/null)"
# o4 near miss: the live machines are never destroyed.
grep -q 'machine destroy m[1-6]live' "$T/fly-calls" && bad "o4: a live machine must never be destroyed: $(grep destroy "$T/fly-calls")" || ok

# o3 the stopped arm.
reset
job m1live LV-1; job m7stop OR-7
printf '[{"id":"m1live","state":"started","updated_at":"%s"},{"id":"m7stop","state":"stopped","updated_at":"%s"}]\n' "$FRESH" "$FRESH" > "$T/listing.json"
tick
[ -f "$MD/m7stop.json" ] && bad "o3: a job on a stopped machine must be released" || ok
[ "$(jq -r '.deaths' "$QD/OR-7.json" 2>/dev/null)" = 1 ] && ok || bad "o3: its key must be requeued: $(ls "$QD")"
grep -q 'machine destroy m7stop' "$T/fly-calls" && ok || bad "o3: the stopped machine must be destroyed: $(cat "$T/fly-calls")"
grep -q 'pool tproj: queued=1 running=1 spawning=1 cap=8$' "$H/logs/fly-pool.log" && ok \
  || bad "o3: the released slot is free the same tick: $(grep -o 'pool tproj: .*' "$H/logs/fly-pool.log")"

echo "fly-pool-orphan-capacity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
