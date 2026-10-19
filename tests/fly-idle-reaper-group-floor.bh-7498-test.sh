#!/bin/bash
# tests/fly-idle-reaper-group-floor.bh-7498-test.sh — the idle reaper keeps a
# lane-run-<group> app to that group's own warm_floor (GET /api/lane-fleet/groups),
# not the global lane_fleet.warm_floor. The default lane-run app keeps the global
# floor; an unreadable groups route keeps the global floor (fail safe: keep).
#   G1 group floor 0, one idle machine past the window: stopped;
#   G2 group floor 1: the machine is kept;
#   G3 default lane-run app keeps the global floor 1 while a group has floor 0;
#   G4 groups route unreadable: global floor, machine kept;
#   G5 a busy machine in a floor-0 group is never stopped;
#   G6 the groups route is read once per pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$DIR/bin/fly-idle-reaper.sh" ] || { echo "FAIL: bin/fly-idle-reaper.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# One clock for the whole file (2026-10-11T06:26:40Z).
NOW=1791700000
FIX="$T/fix"; H="$T/h"; ALL="$T/all-fly-calls"
M1=1a2e00000001; M2=1a2e00000002; M3=1a2e00000003

stub_files() {
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
    "GET /api/lane-fleet/machines") [ -f "$FIX/lr-fail" ] && { JOBS_HTTP=500; return 1; }; cat "$FIX/lr.json" ;;
    "GET /api/lane-fleet/groups") [ -f "$FIX/groups-fail" ] && { JOBS_HTTP=500; return 1; }; cat "$FIX/groups.json" ;;
    "POST /api/fly-idle/stops") echo '{"inserted":1,"ignored":0}' ;;
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
  cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"; echo "$*" >> "$ALL"
case "$1 $2" in
  "apps list") cat "$FIX/apps.json" ;;
  "machine list") cat "$FIX/m-$4.json" 2>/dev/null || { echo "Error: app not found" >&2; exit 1; } ;;
  "machine stop") exit 0 ;;
  # TEST-CHANGE (BH-6877 merge): the reaper probes a lane-run machine with ps
  # before it stops it. This stub answers an idle process list.
  "machine exec") printf '  0.0 /.fly/init\n  0.0 sleep infinity\n' ;;
esac
exit 0
STUB
  chmod +x "$H/bin/lane-alert.sh" "$T/fakebin/flyctl"
  scratch_install_closure bin/fly-idle-reaper.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
  cp "$(rendered_registry)" "$H/catalog/lanes.json"
  # TEST-CHANGE (BH-6877 merge): the probe reads catalog/fly-work-procs.json.
  cp "$DIR/catalog/fly-idle-signals.json" "$DIR/catalog/fly-prices.json" "$DIR/catalog/fly-work-procs.json" "$H/catalog/"
}
stub_files
export FIX ALL

# mach <id> <state> — one lane-run machine, flyctl shape (shared-cpu-1x, the
# fly/lane-run.toml size). Its Fly events are a day old on purpose: the
# lane-run source must not read them.
mach() {
  jq -nc --arg id "$1" --arg st "$2" --argjson s "$((NOW - 86400))" '
    {id:$id, state:$st, config:{guest:{cpu_kind:"shared", cpus:1, memory_mb:1024}},
     events:[{type:"start", status:"started", timestamp:($s*1000)}]}'
}
apps() { printf '%s\n' "$@" | jq -R '{Name: .}' | jq -sc . > "$FIX/apps.json"; }
machines() { local a="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$FIX/m-$a.json"; }
# lr <mid>:<busy>:<in_flight>:<idle_s|-> ... — the GET /api/lane-fleet/machines
# answer, the shape worker/jobs/src/routes/lane-fleet.js returns. LR_INCOMPLETE=1
# sets incomplete: true.
lr() {
  local s
  for s in "$@"; do printf '%s\n' "$s"; done | jq -R 'split(":") |
    {machine_id: .[0], state: "started", started_at: "2026-10-10T06:26:40Z",
     cpu_kind: "shared", cpus: 1, memory_mb: 1024, costed_until: null,
     in_flight: (.[2] == "1"), busy: (.[1] == "1")}
    + (if .[3] == "-" then {} else {idle_s: (.[3] | tonumber)} end)' \
    | jq -sc --argjson inc "${LR_INCOMPLETE:-0}" \
      '{machines: ., start_grace_s: 180, last_failed_at: null, incomplete: ($inc == 1), as_of: "2026-10-11T06:26:40Z"}' \
    > "$FIX/lr.json"
}
reset() {
  scratch_rm "$FIX" >/dev/null 2>&1 || true
  scratch_rm "$H/state" >/dev/null 2>&1 || true
  mkdir -p "$FIX/settings" "$FIX/settings-down" "$H/state/fly-pool" "$H/state/fly"
  rm -f "$H/logs/fly-idle-reaper.log"
  printf 'FLY_API_TOKEN="FlyV1 fm2_fixture"\n' > "$H/env/fly.env"; : > "$H/env/global.env"
  echo '{"queue":[]}' > "$FIX/queue.json"
  apps lane-run
}
floor() { echo "$1" > "$FIX/settings/lane_fleet.warm_floor"; }
run() { # run [epoch]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin" HOME="$T/home" HARNESS="$H" FIX="$FIX" ALL="$ALL" \
    FLY_IDLE_REAPER_NOW="${1:-$NOW}" bash "$H/bin/fly-idle-reaper.sh" 2>&1 </dev/null); RC=$?
}
stops()  { grep -c '^machine stop' "$FIX/fly-calls" 2>/dev/null || true; }
stopped() { grep -q "^machine stop $1 -a lane-run" "$FIX/fly-calls" 2>/dev/null; }
row() { jq -r --arg m "$1" --arg f "$2" '.rows[] | select(.machine_id == $m) | .[$f] | tostring' "$FIX/last-put.json" 2>/dev/null; }
nalert() { local n; n=$(grep -c -- "$1" "$FIX/alert-calls" 2>/dev/null); echo "${n:-0}"; }
lastpass() { grep ' pass apps=' "$H/logs/fly-idle-reaper.log" 2>/dev/null | tail -n 1; }
nlog() { local n; n=$(grep -c -- "$1" "$H/logs/fly-idle-reaper.log" 2>/dev/null); echo "${n:-0}"; }
postrows() { sed -n 's#^POST /api/fly-idle/stops ##p' "$FIX/jobs-calls" 2>/dev/null | jq -c '.rows[]'; }

groups() { # groups <app>:<warm_floor> ...
  local s
  for s in "$@"; do printf '%s\n' "$s"; done | jq -R 'split(":") | {name: .[0], app: .[0], vm_size: "performance-8x",
    vm_memory: 16384, max_machines: 3, warm_floor: (.[1] | tonumber), projects: []}' \
    | jq -sc '{groups: ., invalid: [], group_fallback_s: 60}' > "$FIX/groups.json"
}
gstopped() { grep -q "^machine stop $1 -a $2" "$FIX/fly-calls" 2>/dev/null; }
gcalls() { local n; n=$(grep -c '^GET /api/lane-fleet/groups' "$FIX/jobs-calls" 2>/dev/null); echo "${n:-0}"; }
GM=1a2e0000000a; GA=lane-run-mk

# G1. group floor 0, one idle machine past the window: stopped
reset; floor 1; apps "$GA"; groups "$GA:0"
machines "$GA" "$(mach $GM started)"; lr "$GM:0:0:5000"
run
[ "$RC" = 0 ] && ok || bad "G1 rc $RC: $OUT"
gstopped "$GM" "$GA" && ok || bad "G1 idle machine of a floor-0 group was not stopped: $(cat "$FIX/fly-calls")"
[ "$(gcalls)" = 1 ] && ok || bad "G6 groups route read $(gcalls) times, want 1"

# G2. group floor 1: kept
reset; floor 0; apps "$GA"; groups "$GA:1"
machines "$GA" "$(mach $GM started)"; lr "$GM:0:0:5000"
run
[ "$(stops)" = 0 ] && ok || bad "G2 floor-1 group machine was stopped"
[ "$(row $GM idle_state)" = exempt ] && ok || bad "G2 row is '$(row $GM idle_state)', want exempt"

# G3. default app keeps the global floor while a group has floor 0
reset; floor 1; apps lane-run "$GA"; groups "$GA:0"
machines lane-run "$(mach $M1 started)"; machines "$GA" "$(mach $GM started)"
lr "$M1:0:0:5000" "$GM:0:0:5000"
run
stopped "$M1" && bad "G3 default lane-run machine was stopped despite floor 1" || ok
gstopped "$GM" "$GA" && ok || bad "G3 group machine was not stopped"

# G4. groups route unreadable: global floor 1 keeps the machine
reset; floor 1; apps "$GA"; groups "$GA:0"; : > "$FIX/groups-fail"
machines "$GA" "$(mach $GM started)"; lr "$GM:0:0:5000"
run
[ "$(stops)" = 0 ] && ok || bad "G4 machine stopped with the groups route unreadable"

# G5. busy machine in a floor-0 group is kept
reset; floor 1; apps "$GA"; groups "$GA:0"
machines "$GA" "$(mach $GM started)"; lr "$GM:1:0:0"
run
[ "$(stops)" = 0 ] && ok || bad "G5 busy machine stopped"

echo "fly-idle-reaper-group-floor: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
