#!/bin/bash
# tests/lane-run-wait-alert.bh-6127-test.sh — BH-6127 (BH-6047 part 4 of 5):
# the lane-run queue-wait alert and the metrics it feeds Mission Control.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-run-metrics-worker.bh-6127.mjs, routes in
# worker/jobs/src/routes/lane-runs-metrics.js), through the real
# bin/lane-run-wait-alert.sh and the real bin/lane-alert.sh. The console that
# reads the same answers is console-ui/src/screens/LaneRuns.js through
# console-ui/src/lib/lane-runs-api.js (console-ui/tests/lane-runs.bh-6127.test.js).
#
#   T1  demo queued 15 min ago, 3 ticks: exactly 1 ALERTS line, fired=0,1,0
#   T2  5 demo rows, 2 ticks: 1 alert; metrics carry the counts, the wait and
#       hub.load1 0.42 from the loadavg file; the list carries the 5 runs
#   T3  no JOBS_URL: exit 0, `not-configured`, no ALERTS line
#   T4  the worker answers 500: exit 0, ONE unreachable alert over 2 ticks
#   T5  flags/lane-off-lane-run-wait-alert: no request at all
#   T6  the alert line is the STE template; the script names no model or agent
#   T7  an unsafe lane name in `fire`: no alert, no ack
#   T8  the breach drains: the resolve is written, resolved=1
#
# Run from anywhere: tests/lane-run-wait-alert.bh-6127-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-run-metrics-worker.bh-6127.mjs"
SCRIPT_REL=bin/lane-run-wait-alert.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$SCRIPT_REL" bin/jobs-client.sh bin/lane-alert.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
# Every new source file of BH-6127, by rooted path.
for f in "$DIR/bin/lane-run-wait-alert.sh" "$DIR/worker/jobs/src/routes/lane-runs-metrics.js" \
         "$DIR/console-ui/src/screens/LaneRuns.js" "$DIR/console-ui/src/lib/lane-runs-api.js" \
         "$DIR/tests/lib/lane-run-metrics-worker.bh-6127.mjs"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
[ -x "$H/$SCRIPT_REL" ] && ok "closure installs $SCRIPT_REL" || bad "closure lacks $SCRIPT_REL"
export HARNESS="$H"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_RUN_NOW=1791000000
export BOX_NAME=hub
printf '0.42 0.30 0.20 1/100 4242\n' > "$T/loadavg"
export LANE_RUN_LOADAVG_FILE="$T/loadavg"

PIDS=()
# srv <name> [env...] -> PORT, or rc 3 (no node:sqlite)
srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
seed() { curl -sS -X PUT "$JOBS_URL/__lane_run" -d "$1" >/dev/null; }
run() { "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?; }
lastlog() { tail -1 "$H/logs/lane-run-wait-alert.log" 2>/dev/null; }
nalerts() { grep -c "$1" "$H/logs/ALERTS.log" 2>/dev/null; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-run-wait-alert.log"; scratch_rm "$H/state/alerts"; }

srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"

# --- T1 (WA1): over on ticks 1, 2 and 3 writes exactly ONE alert ------------
RESET
seed '{"lane":"demo","project":"p1","status":"queued","enq_s_ago":900}'
run; R1=$RC; L1=$(lastlog)
run; R2=$RC; L2=$(lastlog)
run; R3=$RC; L3=$(lastlog)
[ "$R1$R2$R3" = 000 ] && ok "T1 every tick exits 0" || bad "T1 rcs $R1 $R2 $R3: $(cat "$T/run.out")"
case "$L1" in *" over=1 fired=0 "*) ok "T1 tick 1: over=1 fired=0" ;; *) bad "T1 tick 1 line: $L1" ;; esac
case "$L2" in *" over=1 fired=1 acked=1 "*) ok "T1 tick 2: fired=1 acked=1" ;; *) bad "T1 tick 2 line: $L2" ;; esac
case "$L3" in *" over=1 fired=0 "*) ok "T1 tick 3: fired=0 (latched)" ;; *) bad "T1 tick 3 line: $L3" ;; esac
[ "$(nalerts 'Lane demo: the oldest queued run waited')" = 1 ] && ok "T1 exactly 1 ALERTS line for demo after 3 ticks" \
  || bad "T1 ALERTS lines: $(nalerts 'Lane demo:') ($(cat "$H/logs/ALERTS.log"))"
case "$L1" in "2026-10-03T04:00:00Z "*) ok "T1 the log stamp comes from LANE_RUN_NOW" ;; *) bad "T1 stamp: $L1" ;; esac

# --- T6: the alert text is the STE template; no LLM call ---------------------
LINE=$(grep 'Lane demo:' "$H/logs/ALERTS.log" | head -1)
case "$LINE" in
  *"Lane demo: the oldest queued run waited 15 min. The limit is 10 min (settings row lane_run.wait_alert_min). 1 runs are queued."*)
    ok "T6 the alert line is the STE template" ;;
  *) bad "T6 alert line: $LINE" ;;
esac
grep -Eq 'agent-call|claude' "$DIR/$SCRIPT_REL" && bad "T6 the script names an agent call or a model" \
  || ok "T6 the script names no agent call and no model"

# --- T8: the breach drains -> one resolve -------------------------------------
curl -sS "$JOBS_URL/__wait_alerts" | jq -e '.rows[0].alerted_at != null' >/dev/null \
  && ok "T8 the ack stamped alerted_at" || bad "T8 no alerted_at after the ack"
curl -sS -X PUT "$JOBS_URL/__lane_run" -d '{"lane":"demo","project":"p1x","status":"done","enq_s_ago":30,"claimed_by":"m1"}' >/dev/null
# Claim the queued demo row through the real claim route.
curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  -d '{"machine":"m1","lanes":["demo"]}' "$JOBS_URL/api/lane-runs/claim" >/dev/null
run; L4=$(lastlog)
case "$L4" in *" over=0 fired=0 acked=0 resolved=1 "*) ok "T8 the drained tick resolves demo" ;; *) bad "T8 line: $L4" ;; esac
grep -q 'demo: the queue wait is under 10 min again' "$H/logs/ALERTS.log" && ok "T8 the resolve line is written" \
  || bad "T8 no resolve line: $(tail -3 "$H/logs/ALERTS.log")"
curl -sS "$JOBS_URL/__wait_alerts" | jq -e '.rows | length == 0' >/dev/null && ok "T8 the latch row is gone" || bad "T8 latch row remains"

# --- T2: the observable outcome, read back through the metrics route ---------
stop_all; PIDS=()
srv w2; export JOBS_URL="http://127.0.0.1:$PORT"
RESET
seed '{"lane":"demo","project":"q1","status":"queued","enq_s_ago":900}'
seed '{"lane":"demo","project":"q2","status":"done","enq_s_ago":600,"claimed_by":"m1"}'
seed '{"lane":"demo","project":"q3","status":"done","enq_s_ago":500,"claimed_by":"m2"}'
seed '{"lane":"demo","project":"q4","status":"claimed","enq_s_ago":400,"claimed_by":"m1"}'
seed '{"lane":"demo","project":"q5","status":"died","enq_s_ago":300,"claimed_by":"m2"}'
run; run
[ "$(nalerts 'Lane demo: the oldest queued run waited')" = 1 ] && ok "T2 2 ticks write exactly 1 alert for demo" \
  || bad "T2 ALERTS: $(cat "$H/logs/ALERTS.log")"
M=$(curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/lane-runs/metrics")
printf '%s' "$M" | jq -e '.lanes[] | select(.lane=="demo") | .queued==1 and .done==2 and .claimed==1 and .died==1 and .wait_max_s >= 900' >/dev/null \
  && ok "T2 metrics: demo counts 1/1/2/1 and wait_max_s >= 900" || bad "T2 metrics lanes: $M"
printf '%s' "$M" | jq -e '.hub.load1 == 0.42 and .hub.box == "hub"' >/dev/null \
  && ok "T2 hub.load1 0.42 round-trips from the loadavg file" || bad "T2 hub: $(printf '%s' "$M" | jq -c .hub)"
case "$(lastlog)" in *" load1=0.42") ok "T2 the summary line names load1" ;; *) bad "T2 line: $(lastlog)" ;; esac
N=$(curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/lane-runs?lane=demo" | jq '.runs | length')
[ "$N" = 5 ] && ok "T2 the list route answers the 5 demo runs" || bad "T2 list has $N runs"

# --- T7: an unsafe lane name in `fire` is refused -----------------------------
RESET
seed '{"lane":"demo; rm -rf /","project":"x1","status":"queued","enq_s_ago":900}'
: > "$T/w2.log"
run; run
grep -q 'rm -rf' "$H/logs/ALERTS.log" && bad "T7 an alert was written for the unsafe name" || ok "T7 no alert for the unsafe lane name"
grep -q '^POST /api/lane-runs/wait-ack' "$T/w2.log" && bad "T7 an ack was sent" || ok "T7 no ack for the unsafe lane name"
grep -q 'skipped unsafe lane name in fire' "$H/logs/lane-run-wait-alert.log" && ok "T7 the skip is logged" || bad "T7 no skip line"

# --- T3: not configured -------------------------------------------------------
RESET
( unset JOBS_URL; JOBS_URL="" "$H/$SCRIPT_REL" ) > "$T/run.out" 2>&1; R=$?
[ "$R" = 0 ] && ok "T3 not configured exits 0" || bad "T3 rc $R"
case "$(lastlog)" in *"not-configured (no-url)") ok "T3 logs not-configured" ;; *) bad "T3 line: $(lastlog)" ;; esac
[ -s "$H/logs/ALERTS.log" ] && bad "T3 an ALERTS line: $(cat "$H/logs/ALERTS.log")" || ok "T3 no ALERTS line"

# --- T4: the worker answers 500 -----------------------------------------------
stop_all; PIDS=()
srv w3 FAIL_ALL=1; export JOBS_URL="http://127.0.0.1:$PORT"
RESET
run; R1=$RC; run; R2=$RC
[ "$R1$R2" = 00 ] && ok "T4 a failed worker exits 0" || bad "T4 rcs $R1 $R2"
case "$(lastlog)" in *"worker-failed (http=500)") ok "T4 logs worker-failed (http=500)" ;; *) bad "T4 line: $(lastlog)" ;; esac
[ "$(nalerts 'The lane-run wait tick failed')" = 1 ] && ok "T4 ONE unreachable alert over 2 failed ticks" \
  || bad "T4 unreachable lines: $(nalerts 'The lane-run wait tick failed')"
grep -q 'over=' "$H/logs/lane-run-wait-alert.log" && bad "T4 a tick was counted" || ok "T4 no tick counted"

# --- T5: the lane-off flag ----------------------------------------------------
RESET
touch "$H/flags/lane-off-lane-run-wait-alert"
: > "$T/w3.log"
run
[ "$RC" = 0 ] && ok "T5 lane off exits 0" || bad "T5 rc $RC"
grep -q 'wait-tick' "$T/w3.log" && bad "T5 a request reached the worker" || ok "T5 no request with the lane off"
rm -f "$H/flags/lane-off-lane-run-wait-alert"

echo "lane-run-wait-alert.bh-6127: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
