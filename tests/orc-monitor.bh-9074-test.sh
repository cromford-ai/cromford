#!/bin/bash
# tests/orc-monitor.bh-9074-test.sh — BH-9074 (BH-9067.2, parent T6): the
# orchestrator monitor runs from the repo. bin/orc-monitor.sh is a gated
# wrapper: kill flag, lane_gate_or_exit orc-monitor, then exec of the hub
# script $ORC/bin/orc-monitor.sh. The hub script is a fake that writes $T/ran
# with its arguments. The gate runs against the REAL jobs worker
# (tests/lib/wakes-worker.bh-9074.mjs); a `curl` on PATH logs any host but
# 127.0.0.1 to $T/net.log.
#
#   O1  run from the repo path: the hub script runs once, args passed through
#   O2  the row switch.monitor-off=1 (lane_switch): exit 0, nothing run
#   O3  flags/lane-off-orc-monitor: exit 0, nothing run (lane_gate_or_exit)
#   O4  the hub script is missing: exit 0, one log line per hour
#   O5  the hub path is a symlink to bin/orc-monitor.sh: exit 0, refused, no loop
#   O6  cadence-backstop.sh orc-monitor: no row runs every tick; row 30 skips the 2nd
#   O7  the shipped registry and the 620 fragment
#   O-real  (the contract #9122 in this tree only) mode on, no ring: exit 0
#       before any work, `lwg orc-monitor fleet skip`; after one ring it runs
#   O9  0 calls to any host but the fake worker
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/orc-monitor.bh-9074-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports the git-ignored catalogs (lanes.json, llm-sites.json).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/wakes-worker.bh-9074.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

export LANE_REGISTRY
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }
PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT

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

N=0
fresh() {
  N=$((N+1))
  H="$T/h$N"; ORC="$T/orc$N"
  mkdir -p "$H/logs" "$H/flags" "$H/env" "$H/catalog/lane-wakes.d" "$ORC/bin" "$ORC/flags"
  ( cd "$DIR" && scratch_install_closure bin/orc-monitor.sh "$H" && scratch_install_closure bin/jobs-client.sh "$H" \
    && scratch_install_closure bin/lib/cadence-backstop.sh "$H" ) >/dev/null 2>&1 || bad "setup: closure install of bin/orc-monitor.sh"
  [ -f "$DIR/catalog/lane-wakes.d/orc-monitor.json" ] && cp "$DIR/catalog/lane-wakes.d/orc-monitor.json" "$H/catalog/lane-wakes.d/"
  cat > "$ORC/bin/orc-monitor.sh" <<STUB
#!/bin/bash
# fake hub monitor: what it was started with
printf '%s\n' "ran \$*" >> "$T/ran.$N"
STUB
  chmod +x "$ORC/bin/orc-monitor.sh"
  : > "$T/w$N.log"; : > "$T/w$N.port"
  export HARNESS="$H" ORC HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 \
    JOBS_OVERLOAD_RETRIES=0 LANE_GATE_CACHE_S=0 BOX_NAME=hub PATH="$T/netbin:$PATH" HARNESS_TEST_SANDBOX=1
  unset LANE_SINGLE_RUN LANE_GATE_RUN CADENCE_BACKSTOP_MIN_ORC_MONITOR
  node "$SRV" "$T/w$N.log" > "$T/w$N.port" 2> "$T/w$N.err" &
  WPID=$!; PIDS+=("$WPID")
  for _ in $(seq 1 200); do [ -s "$T/w$N.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$N.port")
  if [ -z "$PORT" ]; then wait "$WPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/w$N.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}
ran() { local c; c=$(grep -c . "$T/ran.$N" 2>/dev/null); printf '%s' "${c:-0}"; }
cnt() { local c; c=$(grep -cF -- "$1" "$H/logs/orc-monitor.log" 2>/dev/null); printf '%s' "${c:-0}"; }
run() { "$H/bin/orc-monitor.sh" "$@" > "$T/run.out" 2>&1; RC=$?; }
setting() { curl -s -X PUT "$JOBS_URL/__setting" -d "{\"key\":\"$1\",\"value\":\"$2\"}" >/dev/null; }

echo "O1 the repo script runs the hub monitor"
fresh
run --fixture-arg one
eq "O1 exit 0 ($(head -2 "$T/run.out"))" "$RC" 0
eq "O1 the hub script ran once" "$(ran)" 1
eq "O1 args passed through" "$(cat "$T/ran.$N" 2>/dev/null)" "ran --fixture-arg one"
eq "O1 the repo file is the one that ran" "$( [ -f "$DIR/bin/orc-monitor.sh" ] && cmp -s "$DIR/bin/orc-monitor.sh" "$H/bin/orc-monitor.sh" && echo same)" same

echo "O2 the monitor-off switch row"
fresh; setting switch.monitor-off 1
run
eq "O2 exit 0" "$RC" 0
eq "O2 nothing run" "$(ran)" 0

echo "O3 the lane switch (lane_gate_or_exit)"
fresh; touch "$H/flags/lane-off-orc-monitor"
run
eq "O3 exit 0" "$RC" 0
eq "O3 nothing run" "$(ran)" 0
fresh; touch "$H/flags/monitor-off"
run
eq "O3 the monitor-off alias also stops it" "$RC/$(ran)" 0/0

echo "O4 a missing hub script"
fresh; rm -f "$ORC/bin/orc-monitor.sh"
run; run
eq "O4 exit 0" "$RC" 0
eq "O4 one line for two runs in the hour" "$(cnt "orc-monitor: hub script $ORC/bin/orc-monitor.sh missing — nothing run")" 1

echo "O5 a hub path that points back at this file"
fresh; rm -f "$ORC/bin/orc-monitor.sh"; ln -s "$H/bin/orc-monitor.sh" "$ORC/bin/orc-monitor.sh"
timeout 10 "$H/bin/orc-monitor.sh" > "$T/run.out" 2>&1; RC=$?
eq "O5 exit 0, no loop" "$RC" 0
eq "O5 one refuse line" "$(cnt "orc-monitor: hub script is this file — refusing to exec itself")" 1

echo "O6 the cadence backstop row"
fresh
BS="$H/bin/lib/cadence-backstop.sh"
"$BS" orc-monitor; R1=$?; "$BS" orc-monitor; R2=$?
eq "O6 no row: every tick runs" "$R1/$R2" 0/0
fresh
setting lib.cadence-backstop.cadence_backstop_min_orc_monitor 30
"$BS" orc-monitor; R1=$?; "$BS" orc-monitor; R2=$?
eq "O6 row 30: the 1st tick runs, the 2nd is skipped" "$R1/$R2" 0/3
eq "O6 the registry declares the knob, default 0" \
  "$(jq -c '[.libs[] | select(.id=="cadence-backstop") | .knobs[] | select(.env=="CADENCE_BACKSTOP_MIN_ORC_MONITOR") | .default]' "$LANE_REGISTRY")" '[0]'

echo "O7 the shipped registry and cron fragment"
R="$DIR/catalog/lanes.d/orc-monitor.json"
eq "O7 script, wired, no external" "$(jq -c '[.script, .wired, has("external"), has("external_reason")]' "$R")" '["bin/orc-monitor.sh",true,false,false]'
eq "O7 lane-wakes registry" "$(jq -c '[.lane, .scope, .kinds]' "$DIR/catalog/lane-wakes.d/orc-monitor.json" 2>/dev/null)" '["orc-monitor","fleet",[]]'
F="$DIR/cron/lanes/620-orc-monitor.cron"
eq "O7 one active line" "$(grep -v '^#' "$F" | grep -c .)" 1
eq "O7 lease-gated, behind cadence-backstop, the repo script" \
  "$(grep -v '^#' "$F" | grep -cxF '*/5 * * * * /root/harness/bin/hub-lease.sh check && { /root/harness/bin/lib/cadence-backstop.sh orc-monitor; [ $? -ne 3 ]; } && /root/harness/bin/orc-monitor.sh >/dev/null 2>&1')" 1

echo "O-real the contract's wake gate"
if [ -f "$DIR/bin/lib/lane-wake-gate.sh" ] && [ -f "$DIR/worker/jobs/src/routes/lane-wakes.js" ]; then
  fresh
  ( cd "$DIR" && scratch_install_closure bin/lib/lane-wake-gate.sh "$H" && scratch_install_closure bin/fleet-conf.sh "$H" ) >/dev/null 2>&1
  setting lib.lane-wake-gate.mode_orc_monitor on
  LANE_SINGLE_RUN=1 "$H/bin/orc-monitor.sh" > "$T/run.out" 2>&1; RC=$?
  eq "O-real a first tick (no watermark) runs" "$RC/$(ran)" 0/1
  rm -f "$T/ran.$N"
  LANE_SINGLE_RUN=1 "$H/bin/orc-monitor.sh" > "$T/run.out" 2>&1; RC=$?
  eq "O-real mode on, no ring: exit 0" "$RC" 0
  eq "O-real mode on, no ring: nothing run" "$(ran)" 0
  eq "O-real skip logged" "$(grep -c 'lwg orc-monitor fleet skip$' "$H/logs/lane-wake-gate.log" 2>/dev/null)" 1
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_ring orc-monitor fleet cal:20261109t1100' >/dev/null 2>&1
  RID=$(curl -s "$JOBS_URL/__wakes?repo=harness/lanes" | jq -r '.ids[0]')
  LANE_SINGLE_RUN=1 "$H/bin/orc-monitor.sh" > "$T/run.out" 2>&1; RC=$?
  eq "O-real after one ring it runs" "$RC/$(ran)" 0/1
  eq "O-real run wake=<id> logged" "$(grep -c "lwg orc-monitor fleet run wake=$RID\$" "$H/logs/lane-wake-gate.log" 2>/dev/null)" 1
else
  echo "  SKIPPED: contract #9122 not in this tree (no bin/lib/lane-wake-gate.sh)"
fi

echo "O9 budget: 0 vendor calls"
eq "O9 net.log is empty ($(head -3 "$T/net.log"))" "$(grep -c . "$T/net.log")" 0

echo "orc-monitor: $PASS passed, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
