#!/bin/bash
# tests/fly-idle-usage.bh-6877-test.sh — the Fly idle reaper stops a started
# machine only when no witness shows work, and destroys a machine stopped for
# more than fly.destroy_after_stopped_s (BH-6877).
#
# WHAT THIS PINS. The REAL bin/fly-idle-reaper.sh, installed with its closure
# into a scratch $HARNESS, against stubs on PATH: flyctl (apps, machines, exec,
# stop and destroy from fixtures, every call recorded), curl (the Fly
# Prometheus API from fixtures), a jobs-client stub (settings from files, the
# claimed queue and GET /api/lane-fleet/machines from fixtures, every request
# recorded), a lane-alert recorder. One fixed clock.
#   U1-U7  lane-run source, start/launch-only events, work stamps, warm floor
#   N1-N3  boot-without-claim alert, one per image digest, alert only
#   P1-P5  the ps probe before a stop
#   M1-M5  the metrics default signal, project-12 registry rows
#   D1-D12 the destroy step; D10-D12 a recorded builder, a mounted volume and
#          an unreadable state/fly record are never destroyed
#   I1     every image of a probed app (pool, builder, lane-run) installs ps
#   G1     the pass line counters
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-usage.bh-6877-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in "$DIR/bin/fly-idle-reaper.sh" "$DIR/bin/lib/fly-metrics.sh" "$DIR/catalog/fly-work-procs.json" \
  "$DIR/catalog/fly-idle-signals.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# 2026-10-11T06:26:40Z, pinned (D60).
NOW=1791700000
FIX="$T/fix"; H="$T/h"
P1=1f1d00000001; L1=1f1d000000f1; L2=1f1d000000f2; L3=1f1d000000f3; X1=1f1d000000e1; S1=1f1d000000a2

mkdir -p "$H/bin" "$H/catalog" "$H/flags" "$H/logs" "$H/state" "$H/env" "$H/locks" "$T/fakebin" "$T/home"
cat > "$H/bin/jobs-client.sh" <<'STUB'
JOBS_BOX=fixture
_jobs_box_name() { echo fixture; }
flag_sync() { return 1; }
setting_get() {
  [ -f "$FIX/settings-down/$1" ] && return 1
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FIX/jobs-calls"
  case "$1 $2" in
    "GET /api/queue"*) cat "$FIX/queue.json" ;;
    "GET /api/lane-fleet/machines") [ -f "$FIX/lane-fail" ] && return 1; cat "$FIX/lane.json" ;;
    "POST /api/fly-idle/stops") echo '{"inserted":1,"ignored":0}' ;;
    "POST /api/fly-idle/destroys") [ -f "$FIX/dpost-fail" ] && return 1; echo '{"inserted":1,"ignored":0}' ;;
    "PUT /api/fly-idle/machines") printf '%s' "${3:-}" > "$FIX/last-put.json"; echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
STUB
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
exit 0
STUB
cat > "$H/bin/testhost-tick.sh" <<'STUB'
#!/bin/bash
echo 0
STUB
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 $2" in
  "apps list") cat "$FIX/apps.json" ;;
  "machine list") cat "$FIX/m-$4.json" 2>/dev/null || { echo "Error: app not found" >&2; exit 1; } ;;
  "machine exec")
    rc=$(cat "$FIX/exec-rc-$3" 2>/dev/null || cat "$FIX/exec-rc" 2>/dev/null || echo 0)
    cat "$FIX/exec-$3" 2>/dev/null || cat "$FIX/exec-out" 2>/dev/null
    exit "$rc" ;;
  "machine stop") exit 0 ;;
  "machine destroy") exit "$(cat "$FIX/destroy-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
# curl: only the Prometheus query is answered; the query text picks the file.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/curl-calls"
[ -f "$FIX/prom-fail" ] && exit 22
for a in "$@"; do
  case "$a" in
    query=*cpu*) cat "$FIX/prom-cpu.json"; exit 0 ;;
    query=*net*) cat "$FIX/prom-net.json"; exit 0 ;;
  esac
done
exit 22
STUB
chmod +x "$H/bin/lane-alert.sh" "$H/bin/testhost-tick.sh" "$T/fakebin/flyctl" "$T/fakebin/curl"
scratch_install_closure bin/fly-idle-reaper.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cp "$DIR/catalog/fly-idle-signals.json" "$DIR/catalog/fly-prices.json" "$DIR/catalog/fly-work-procs.json" "$H/catalog/"
export FIX

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# mach <id> <state> <start-epoch> [stop-epoch|-] [update-epoch|-] [digest|-] — one
# machine in the flyctl `machine list --json` shape. Events newest first.
mach() {
  jq -nc --arg id "$1" --arg st "$2" --argjson s "$3" --arg x "${4:--}" --arg u "${5:--}" --arg d "${6:--}" '
    {id:$id, state:$st, config:{guest:{cpu_kind:"performance", cpus:16, memory_mb:32768},
                                image:"registry.fly.io/lane-run:latest"},
     image_ref:(if $d == "-" then null else {digest:$d} end),
     events:([(if $u == "-" then empty else {type:"update", status:"updated", timestamp:(($u|tonumber)*1000)} end),
              (if $x == "-" then empty else {type:"exit", status:"stopped", timestamp:(($x|tonumber)*1000)} end),
              {type:"start", status:"started", timestamp:($s*1000)},
              {type:"launch", status:"created", timestamp:(($s-30)*1000)}]
             | sort_by(-.timestamp))}'
}
apps() { printf '%s\n' "$@" | jq -R '{Name: ., Organization: {Slug: "fixture-org"}}' | jq -sc . > "$FIX/apps.json"; }
machines() { local a="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$FIX/m-$a.json"; }
# lrow <id> <state> <started-epoch> <busy> <in_flight> <idle_s> — one row of
# GET /api/lane-fleet/machines (worker/jobs/src/routes/lane-fleet.js).
lrow() {
  jq -nc --arg id "$1" --arg st "$2" --arg at "$(iso "$3")" --argjson b "$4" --argjson f "$5" --argjson i "$6" '
    {machine_id:$id, state:$st, started_at:$at, cpu_kind:"performance", cpus:16, memory_mb:32768,
     costed_until:null, in_flight:$f, busy:$b, idle_s:$i}'
}
lane() { printf '%s\n' "$@" | jq -sc --arg at "$(iso "$NOW")" \
  '{machines: ., start_grace_s: 180, last_failed_at: null, incomplete: false, as_of: $at}' > "$FIX/lane.json"; }
# prom <file> <instance> <value> ... — a Prometheus instant-vector answer.
prom() {
  local f="$1"; shift; local rows=()
  while [ $# -ge 2 ]; do rows+=("$(jq -nc --arg i "$1" --arg v "$2" '{metric:{app:"x", instance:$i}, value:[1791700000, $v]}')"); shift 2; done
  printf '%s\n' "${rows[@]}" | jq -sc '{status:"success", data:{resultType:"vector", result:.}}' > "$FIX/$f"
}
IDLE_PS=$'  0.0 /.fly/init\n  0.0 /bin/bash /root/harness/bin/lane-run-worker.sh\n  0.0 sleep infinity\n  0.0 ps -eo pcpu=,args='
reset() {
  scratch_rm "$FIX" >/dev/null 2>&1 || true
  scratch_rm "$H/state" >/dev/null 2>&1 || true
  mkdir -p "$FIX/settings" "$FIX/settings-down" "$H/state/fly-pool/cromford" "$H/state/fly"
  rm -f "$H/logs/fly-idle-reaper.log"
  printf 'FLY_API_TOKEN="FlyV1 fm2_fixture"\n' > "$H/env/fly.env"; : > "$H/env/global.env"
  echo '{"queue":[]}' > "$FIX/queue.json"
  printf '%s\n' "$IDLE_PS" > "$FIX/exec-out"
  echo 0 > "$FIX/settings/lane_fleet.warm_floor"
  lane
  apps pool-cromford; machines pool-cromford
}
run() { # run [epoch]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin" HOME="$T/home" HARNESS="$H" FIX="$FIX" \
    FLY_IDLE_REAPER_NOW="${1:-$NOW}" bash "$H/bin/fly-idle-reaper.sh" 2>&1 </dev/null); RC=$?
}
stopped()   { grep -q "^machine stop $1 -a $2" "$FIX/fly-calls" 2>/dev/null; }
destroyed() { grep -q "^machine destroy $1 -a $2" "$FIX/fly-calls" 2>/dev/null; }
n_of()  { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
execs() { n_of "^machine exec" "$FIX/fly-calls"; }
row_state() { jq -r --arg m "$1" '.rows[] | select(.machine_id == $m) | .idle_state' "$FIX/last-put.json" 2>/dev/null; }
row_field() { jq -r --arg m "$1" --arg k "$2" '.rows[] | select(.machine_id == $m) | .[$k] | tostring' "$FIX/last-put.json" 2>/dev/null; }
lastpass() { grep ' pass apps=' "$H/logs/fly-idle-reaper.log" 2>/dev/null | tail -n 1; }
stop_post() { grep '^POST /api/fly-idle/stops ' "$FIX/jobs-calls" | head -n 1 | cut -d' ' -f3-; }

# ── U1. lane-run: fresh Fly events, no claim for 901 s → stopped ───────────
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 901)) - $((NOW - 30)))"
lane "$(lrow $L1 started $((NOW - 901)) false false 901)"
run
[ "$RC" = 0 ] && ok || bad "U1 rc $RC: $OUT"
stopped $L1 lane-run && ok || bad "U1 a lane-run machine idle 901 s with fresh events was not stopped: $(cat "$FIX/fly-calls")"
[ "$(stop_post | jq -r '.rows[0].source')" = lane-run ] && ok || bad "U1 the stop row source is not lane-run: $(stop_post)"
[ "$(stop_post | jq -r '.rows[0].idle_s')" = 901 ] && ok || bad "U1 the stop row idle_s is not 901: $(stop_post)"
grep -q '^GET /api/lane-fleet/machines' "$FIX/jobs-calls" && ok || bad "U1 the lane-fleet route was not read"
# ── U2. a claim 100 s ago → not stopped ────────────────────────────────────
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 5000)))"
lane "$(lrow $L1 started $((NOW - 5000)) false false 100)"; run
stopped $L1 lane-run && bad "U2 a lane-run machine with a claim 100 s ago was stopped" || ok
[ "$(row_state $L1)" = idle ] && [ "$(row_field $L1 idle_s)" = 100 ] && ok || bad "U2 row is $(row_state $L1)/$(row_field $L1 idle_s), want idle/100"
# ── U3. busy=true → not stopped; in_flight → not stopped ───────────────────
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 5000)))" "$(mach $L2 started $((NOW - 5000)))"
lane "$(lrow $L1 started $((NOW - 5000)) true false 0)" "$(lrow $L2 starting $((NOW - 5000)) false true 5000)"; run
stopped $L1 lane-run && bad "U3 a busy lane-run machine was stopped" || ok
stopped $L2 lane-run && bad "U3 an in_flight lane-run machine was stopped" || ok
[ "$(row_state $L1)" = busy ] && ok || bad "U3 the busy row is '$(row_state $L1)'"
[ -f "$H/state/fly-idle-reaper/work/lane-run__$L1" ] && ok || bad "U3 a busy lane-run machine wrote no work stamp"
# ── U4. pool: an update event does not reset idle; a witness does ──────────
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)) - $((NOW - 30)))"; run
stopped $P1 pool-cromford && ok || bad "U4a a pool machine with only an update event 30 s ago (start 1000 s ago) was not stopped"
[ "$(stop_post | jq -r '.rows[0].idle_s')" = 1000 ] && ok || bad "U4a idle_s is not 1000: $(stop_post)"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)) - $((NOW - 30)))"
echo '{}' > "$H/state/fly-pool/cromford/$P1.json"; run
stopped $P1 pool-cromford && bad "U4b a pool machine with a tracking file was stopped" || ok
[ "$(cat "$H/state/fly-idle-reaper/work/pool-cromford__$P1" 2>/dev/null)" = "$NOW" ] && ok || bad "U4b the work stamp is not $NOW"
[ "$(row_field $P1 last_work_at)" = "$(iso "$NOW")" ] && ok || bad "U4b last_work_at is '$(row_field $P1 last_work_at)'"
# ── U7. the stamp from that pass is the idle start on the next ─────────────
rm -f "$H/state/fly-pool/cromford/$P1.json"; : > "$FIX/fly-calls"
run $((NOW + 600))
stopped $P1 pool-cromford && bad "U7 600 s after the stamp the machine was stopped" || ok
[ "$(row_field $P1 idle_s)" = 600 ] && ok || bad "U7 idle_s is '$(row_field $P1 idle_s)', want 600 (from the stamp)"
run $((NOW + 1000))
stopped $P1 pool-cromford && ok || bad "U7 1000 s after the stamp the machine was not stopped"
# ── U5. the warm floor keeps the lowest-idle lane-run machine ──────────────
reset; apps lane-run; echo 1 > "$FIX/settings/lane_fleet.warm_floor"
machines lane-run "$(mach $L1 started $((NOW - 9000)))" "$(mach $L2 started $((NOW - 9000)))" "$(mach $L3 started $((NOW - 9000)))"
# L3 is over the limit too (1000 s), so only the floor keeps it.
lane "$(lrow $L1 started $((NOW - 9000)) false false 5000)" "$(lrow $L2 started $((NOW - 9000)) false false 2000)" \
  "$(lrow $L3 started $((NOW - 9000)) false false 1000)"
run
stopped $L1 lane-run && stopped $L2 lane-run && ok || bad "U5 the two higher-idle machines were not both stopped: $(cat "$FIX/fly-calls")"
stopped $L3 lane-run && bad "U5 the warm-floor machine (lowest idle) was stopped" || ok
# ── U6. the lane-fleet route fails: unknown, alert on the third pass ───────
reset; apps lane-run; machines lane-run "$(mach $L1 started $((NOW - 9000)))"; touch "$FIX/lane-fail"
run
stopped $L1 lane-run && bad "U6 a lane-run machine was stopped with the route unreadable" || ok
[ "$(row_state $L1)" = unknown ] && ok || bad "U6 the row is '$(row_state $L1)', want unknown"
run
[ "$(n_of 'severity warn --id fly-idle-fail-lane-run ' "$FIX/alert-calls")" = 0 ] && ok || bad "U6 pass 2 alerted"
run
[ "$(n_of 'severity warn --id fly-idle-fail-lane-run ' "$FIX/alert-calls")" = 1 ] && ok || bad "U6 pass 3 did not send one fail alert"
# incomplete:true is unread too.
reset; apps lane-run; machines lane-run "$(mach $L1 started $((NOW - 9000)))"
lane "$(lrow $L1 started $((NOW - 9000)) false false 5000)"
jq -c '.incomplete = true' "$FIX/lane.json" > "$FIX/l2" && mv "$FIX/l2" "$FIX/lane.json"; run
[ "$(row_state $L1)" = unknown ] && ok || bad "U6b incomplete:true gave '$(row_state $L1)', want unknown"
# A started Fly machine with no lane row is unknown.
reset; apps lane-run; machines lane-run "$(mach $L1 started $((NOW - 9000)))"; lane; run
[ "$(row_state $L1)" = unknown ] && ok || bad "U6c a machine with no lane row gave '$(row_state $L1)', want unknown"

# ── N1-N3. boot without a claim: one alert per image digest ────────────────
# A 64-hex literal is a credential to bin/share/leakcheck.py, so the fake
# digest is built at run time (the blocked-resolver-offhub.bh-6128 SHA64 form).
DA="sha256:$(printf '%064d' 0 | tr 0 a)"
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 601)) - - $DA)"
lane "$(lrow $L1 starting $((NOW - 601)) false false 601)"; run
[ "$(n_of 'severity warn --id fly-no-claim-aaaaaaaaaaaa ' "$FIX/alert-calls")" = 1 ] && ok || bad "N1 want 1 no-claim alert: $(cat "$FIX/alert-calls" 2>/dev/null)"
[ "$(row_field $L1 no_claim)" = true ] && ok || bad "N1 the snapshot no_claim is '$(row_field $L1 no_claim)'"
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 601)) - - $DA)" "$(mach $L2 started $((NOW - 700)) - - $DA)"
lane "$(lrow $L1 starting $((NOW - 601)) false false 601)" "$(lrow $L2 starting $((NOW - 700)) false false 700)"
run; run $((NOW + 60))
[ "$(n_of 'id fly-no-claim-' "$FIX/alert-calls")" = 1 ] && ok || bad "N2 two machines, two passes: want 1 alert line in total: $(cat "$FIX/alert-calls" 2>/dev/null)"
case "$(lastpass)" in *"noclaim=2"*) ok ;; *) bad "N2 the pass line does not count noclaim=2: $(lastpass)" ;; esac
# The digest clears when no machine of it is unclaimed.
lane "$(lrow $L1 started $((NOW - 601)) false false 10)" "$(lrow $L2 started $((NOW - 700)) false false 10)"; run $((NOW + 120))
[ "$(n_of 'resolve --id fly-no-claim-aaaaaaaaaaaa ' "$FIX/alert-calls")" = 1 ] && ok || bad "N2 the digest alert was not resolved"
reset; apps lane-run
machines lane-run "$(mach $L1 started $((NOW - 599)) - - $DA)" "$(mach $L2 started $((NOW - 2000)) - - $DA)"
lane "$(lrow $L1 starting $((NOW - 599)) false false 599)" "$(lrow $L2 started $((NOW - 2000)) false false 10)"; run
[ "$(n_of 'id fly-no-claim-' "$FIX/alert-calls")" = 0 ] && ok || bad "N3 599 s or a claimed machine alerted"
[ "$(n_of '^machine stop' "$FIX/fly-calls")" = 0 ] && ok || bad "N3 the alert path stopped a machine"

# ── P1-P5. the ps probe before a stop ──────────────────────────────────────
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"
printf ' 12.0 bash /root/harness/bin/run-build.sh project-6-os TK-580\n  0.0 /.fly/init\n' > "$FIX/exec-out"; run
[ "$(execs)" = 1 ] && ok || bad "P1 want one machine exec, got $(execs)"
grep -q "^machine exec $P1 ps -eo pcpu=,args= -a pool-cromford" "$FIX/fly-calls" && ok || bad "P1 the probe command is wrong: $(grep exec "$FIX/fly-calls")"
stopped $P1 pool-cromford && bad "P1 a machine running run-build.sh was stopped" || ok
[ "$(row_state $P1)" = busy ] && ok || bad "P1 the row is '$(row_state $P1)', want busy"
[ "$(cat "$H/state/fly-idle-reaper/work/pool-cromford__$P1" 2>/dev/null)" = "$NOW" ] && ok || bad "P1 a busy probe wrote no work stamp"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"
printf '  0.0 /bin/bash /root/harness/bin/wait-preview.sh mk 12\n  0.0 sleep infinity\n' > "$FIX/exec-out"; run
stopped $P1 pool-cromford && bad "P2 a machine running wait-preview.sh was stopped" || ok
reset; apps lane-run; machines lane-run "$(mach $L1 started $((NOW - 1000)))"
lane "$(lrow $L1 started $((NOW - 1000)) false false 1000)"
printf '  0.0 /bin/bash lane-run-worker.sh\n  0.0 sleep infinity\n' > "$FIX/exec-out"; run
stopped $L1 lane-run && ok || bad "P3 a lane-run machine with only the idle loop was not stopped"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"; echo 1 > "$FIX/exec-rc"; run
stopped $P1 pool-cromford && bad "P4 a failed probe stopped the machine" || ok
[ "$(row_state $P1)" = unknown ] && ok || bad "P4 the row is '$(row_state $P1)', want unknown"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"; : > "$FIX/exec-out"; run
stopped $P1 pool-cromford && bad "P4b an empty probe answer stopped the machine" || ok
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"
printf '  7.0 /usr/local/bin/mystery-daemon\n  0.0 /.fly/init\n' > "$FIX/exec-out"; run
stopped $P1 pool-cromford && bad "P5a an unknown process at 7.0% was stopped" || ok
[ "$(row_state $P1)" = busy ] && ok || bad "P5a the row is '$(row_state $P1)', want busy"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"
printf '  1.0 /usr/local/bin/mystery-daemon\n  0.0 /.fly/init\n' > "$FIX/exec-out"; run
stopped $P1 pool-cromford && ok || bad "P5b an unknown process at 1.0% held the machine"
# A procs catalog that does not validate stops nothing that needs a probe.
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))"
cp "$H/catalog/fly-work-procs.json" "$T/procs.bak"; echo '{"work":"x"}' > "$H/catalog/fly-work-procs.json"; run
stopped $P1 pool-cromford && bad "P6 a bad procs catalog still stopped" || ok
[ "$(n_of 'id fly-idle-reaper-procs ' "$FIX/alert-calls")" = 1 ] && ok || bad "P6 a bad procs catalog raised no alert"
cp "$T/procs.bak" "$H/catalog/fly-work-procs.json"

# ── M1-M5. the metrics default signal ──────────────────────────────────────
mquiet() { prom prom-cpu.json "$1" "$2"; prom prom-net.json "$1" "$3"; }
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 2000)))"; mquiet $X1 0.5 100; run
stopped $X1 mystery-app && ok || bad "M1 an unregistered app at 0.5% / 100 B/s was not stopped: $(cat "$FIX/fly-calls")"
[ "$(stop_post | jq -r '.rows[0].source')" = metrics ] && ok || bad "M1 the stop row source is not metrics: $(stop_post)"
[ "$(execs)" = 0 ] && ok || bad "M1 a metrics app was probed with machine exec"
grep -q 'fixture-org/api/v1/query' "$FIX/curl-calls" && ok || bad "M1 the query did not go to the org's Prometheus path: $(cat "$FIX/curl-calls" 2>/dev/null)"
grep -q 'fm2_fixture' "$FIX/curl-calls" && bad "M1 the token is on the curl command line" || ok
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 2000)))"; mquiet $X1 30 100; run
stopped $X1 mystery-app && bad "M2 a 30% CPU machine was stopped" || ok
[ "$(row_state $X1)" = busy ] && ok || bad "M2 the row is '$(row_state $X1)', want busy"
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 2000)))"; mquiet $X1 0 51200; run
stopped $X1 mystery-app && bad "M2b a 50 KB/s machine was stopped" || ok
reset; apps project-12-acme; machines project-12-acme "$(mach $X1 started $((NOW - 90000)))"; mquiet $X1 0 0; run
stopped $X1 project-12-acme && bad "M3 a project-12- customer bot was stopped" || ok
[ "$(row_state $X1)" = exempt ] && ok || bad "M3 the row is '$(row_state $X1)', want exempt"
reset; apps project-12-openfang-joy; machines project-12-openfang-joy "$(mach $X1 started $((NOW - 90000)))"; mquiet $X1 0 0; run
stopped $X1 project-12-openfang-joy && ok || bad "M4 project-12-openfang-joy (exact metrics entry) was not stopped"
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 2000)))"; touch "$FIX/prom-fail"; run
stopped $X1 mystery-app && bad "M5 a failed metrics read stopped the machine" || ok
[ "$(row_state $X1)" = unknown ] && ok || bad "M5 the row is '$(row_state $X1)', want unknown"
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 2000)))"; prom prom-cpu.json; prom prom-net.json; run
[ "$(row_state $X1)" = unknown ] && ok || bad "M5b a missing series gave '$(row_state $X1)', want unknown"
# A machine younger than the window is under the limit, not over.
reset; apps mystery-app; machines mystery-app "$(mach $X1 started $((NOW - 300)))"; mquiet $X1 0 0; run
stopped $X1 mystery-app && bad "M6 a 300 s old quiet machine was stopped" || ok
[ "$(row_state $X1)" = idle ] && ok || bad "M6 the row is '$(row_state $X1)', want idle"
jq -e '.prefixes["project-12-"].source == "exempt"' "$DIR/catalog/fly-idle-signals.json" >/dev/null && ok || bad "M7 the project-12- prefix is not exempt"

# ── D1-D5. the destroy step ────────────────────────────────────────────────
reset; machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
destroyed $S1 pool-cromford && ok || bad "D1 a pool machine stopped 8 d was not destroyed: $(cat "$FIX/fly-calls")"
grep -q -- '--force' "$FIX/fly-calls" && bad "D1 destroy used --force" || ok
DPOST=$(grep '^POST /api/fly-idle/destroys ' "$FIX/jobs-calls" | head -n 1 | cut -d' ' -f3-)
[ "$(printf '%s' "$DPOST" | jq -r '.rows[0].stopped_s')" = 691200 ] && ok || bad "D1 the destroy row stopped_s is wrong: $DPOST"
[ "$(printf '%s' "$DPOST" | jq -r '.rows[0].usd_per_hour | type')" = number ] && ok || bad "D1 the destroy row has no usd_per_hour: $DPOST"
norm() { jq -S 'walk(if type == "number" then . + 0 else . end)' 2>/dev/null; }
DFX="$DIR/worker/jobs/test/fixtures/fly-idle-destroy.bh-6877.json"
if [ -f "$DFX" ] && [ -n "$DPOST" ] && [ "$(printf '%s' "$DPOST" | norm)" = "$(norm < "$DFX")" ]; then ok
else bad "D1 worker/jobs/test/fixtures/fly-idle-destroy.bh-6877.json differs from the reaper's POST body: $DPOST"; fi
[ -z "$(ls -A "$H/state/fly-idle-reaper/outbox-destroy" 2>/dev/null)" ] && ok || bad "D1 the destroy outbox is not empty after a good POST"
reset; apps bh-ci-runners-example-org bh-testhost-example-org mystery-app
machines bh-ci-runners-example-org "$(mach $S1 stopped $((NOW - 3000000)) $((NOW - 2592000)))"
machines bh-testhost-example-org "$(mach 1f1d000000a3 stopped $((NOW - 3000000)) $((NOW - 2592000)))"
machines mystery-app "$(mach 1f1d000000a4 stopped $((NOW - 3000000)) $((NOW - 2592000)))"; run
[ "$(n_of '^machine destroy' "$FIX/fly-calls")" = 0 ] && ok || bad "D2 an exempt, testhost or metrics machine stopped 30 d was destroyed: $(cat "$FIX/fly-calls")"
reset; machines pool-cromford "$(mach $S1 stopped $((NOW - 600000)) $((NOW - 518400)))" \
  "$(mach 1f1d000000a5 stopped $((NOW - 700000)) $((NOW - 604800)))"; run
[ "$(n_of '^machine destroy' "$FIX/fly-calls")" = 0 ] && ok || bad "D3 6 d or exactly 604800 s was destroyed"
reset; echo 0 > "$FIX/settings/fly.destroy_enabled"
machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
destroyed $S1 pool-cromford && bad "D4 fly.destroy_enabled=0 still destroyed" || ok
reset; echo 1 > "$FIX/destroy-rc"; machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
grep -q '^POST /api/fly-idle/destroys' "$FIX/jobs-calls" && bad "D5 a failed destroy posted a row" || ok
case "$(lastpass)" in *"destroying=0 destroy_failed=1"*) ok ;; *) bad "D5 the pass line: $(lastpass)" ;; esac
# A failed POST keeps the row for the next pass.
reset; touch "$FIX/dpost-fail"; machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
[ "$(ls "$H/state/fly-idle-reaper/outbox-destroy/" 2>/dev/null | wc -l)" = 1 ] && ok || bad "D6 a failed destroy POST left no outbox file"
rm -f "$FIX/dpost-fail"; machines pool-cromford; run
[ -z "$(ls -A "$H/state/fly-idle-reaper/outbox-destroy" 2>/dev/null)" ] && ok || bad "D6 the next pass did not post the destroy outbox"
# The per-pass destroy cap.
reset; echo 2 > "$FIX/settings/fly.destroy_max_per_pass"
machines pool-cromford "$(mach 1f1d000000b1 stopped $((NOW - 900000)) $((NOW - 800000)))" \
  "$(mach 1f1d000000b2 stopped $((NOW - 900000)) $((NOW - 800000)))" "$(mach 1f1d000000b3 stopped $((NOW - 900000)) $((NOW - 800000)))"; run
[ "$(n_of '^machine destroy' "$FIX/fly-calls")" = 2 ] && ok || bad "D7 the cap 2 gave $(n_of '^machine destroy' "$FIX/fly-calls") destroys"

# A window under a day is refused, never clamped: no destroy that pass.
reset; echo 3600 > "$FIX/settings/fly.destroy_after_stopped_s"
machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
destroyed $S1 pool-cromford && bad "D8 fly.destroy_after_stopped_s=3600 still destroyed" || ok
grep -q 'fly.destroy_after_stopped_s=3600 is under 86400' "$H/logs/fly-idle-reaper.log" && ok || bad "D8 the refusal is not logged"
# An unreadable destroy row is no destroy, and the stops still run.
reset; : > "$FIX/settings-down/fly.destroy_enabled"
machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))" "$(mach $P1 started $((NOW - 1000)))"; run
destroyed $S1 pool-cromford && bad "D9 an unreadable fly.destroy_enabled still destroyed" || ok
stopped $P1 pool-cromford && ok || bad "D9 an unreadable destroy row also stopped the stops"

# A project's recorded persistent builder (bin/fly-provision.sh) is never
# destroyed: fly-dispatch starts that id, and only an operator makes it again.
B1=1f1d000000c1
reset; apps builder-acme; printf '{"app":"builder-acme","machine_id":"%s","volume_id":"vol_x"}\n' "$B1" > "$H/state/fly/acme.json"
machines builder-acme "$(mach $B1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
destroyed $B1 builder-acme && bad "D10 the recorded builder of state/fly/acme.json was destroyed after 8 d" || ok
grep -q "builder-acme/$B1: stopped 691200s, not destroyed: it is the recorded builder" "$H/logs/fly-idle-reaper.log" && ok || bad "D10 the keep is not logged"
# The same machine with no record but a mounted volume: kept.
reset; apps builder-acme
machines builder-acme "$(mach $B1 stopped $((NOW - 700000)) $((NOW - 691200)) | jq -c '.config.mounts = [{volume:"vol_x", path:"/data"}]')"; run
destroyed $B1 builder-acme && bad "D11 a machine with a mounted volume was destroyed" || ok
# An unreadable state/fly record: no destroy that pass, in any app.
reset; apps builder-acme pool-cromford; echo '{not json' > "$H/state/fly/acme.json"
machines builder-acme "$(mach $B1 stopped $((NOW - 700000)) $((NOW - 691200)))"
machines pool-cromford "$(mach $S1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
[ "$(n_of '^machine destroy' "$FIX/fly-calls")" = 0 ] && ok || bad "D12 an unreadable state/fly record still destroyed: $(cat "$FIX/fly-calls")"
# A stopped builder with no record and no volume is still destroyed.
reset; apps builder-acme; machines builder-acme "$(mach $B1 stopped $((NOW - 700000)) $((NOW - 691200)))"; run
destroyed $B1 builder-acme && ok || bad "D12b an unrecorded builder machine with no volume was not destroyed"

# ── I1. the probe needs `ps` in every image of a probed app ────────────────
# A machine without ps answers the probe rc != 0 (unknown), so it is never
# stopped: lane-run (BH-6126) shipped without procps.
for df in fly/Dockerfile fly/lane-run.Dockerfile; do
  grep -Eq '^[^#]*\bprocps\b' "$DIR/$df" && ok || bad "I1 $df does not install procps: the reaper probe (ps) fails on its machines"
done

# ── G1. the pass line ──────────────────────────────────────────────────────
reset; run
for k in probed= probe_busy= destroying= destroy_failed= noclaim= metrics=; do
  case "$(lastpass)" in *" $k"[0-9]*) ok ;; *) bad "G1 the pass line has no $k: $(lastpass)" ;; esac
done

echo "fly-idle-usage: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
