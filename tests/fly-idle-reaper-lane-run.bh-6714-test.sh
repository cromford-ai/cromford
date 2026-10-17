#!/bin/bash
# tests/fly-idle-reaper-lane-run.bh-6714-test.sh — the fly-idle-reaper source
# `lane-run`: a lane-run machine is stopped on the idle_s that
# GET /api/lane-fleet/machines reports, the lane_fleet.warm_floor machines are
# kept, and an answer the reaper cannot read stops nothing (BH-6714).
#
# WHAT THIS PINS. The REAL bin/fly-idle-reaper.sh, installed with its closure
# into a scratch $HARNESS, against a flyctl stub on PATH (apps and machines from
# fixtures, every call recorded), a jobs-client stub (settings from files, the
# lane-fleet answer from a fixture, every request recorded) and a lane-alert
# recorder. One fixed clock for the whole file.
#   L1  one machine, default floor 1: kept, never nosignal;
#   L2  floor 1 of three: the two most idle are stopped, the stop rows say lane-run;
#   L3  busy and in_flight are busy; a busy machine fills the floor;
#   L4  an unreadable answer: unknown, one log line per pass, alert at 3, resolve;
#   L5  floor row 0 and an out-of-range floor row;   L6 an unreadable floor row;
#   L7  incomplete: true;   L8 no record row, and a row with no idle_s;
#   L9  the per-pass stop cap;   L10 the old nosignal condition is resolved;
#   L11 the floor beats the threshold; 900 s is not "more than 900";
#   L12 no started lane-run machine, no read;   L13 the token stays out;
#   L14 a record row Fly does not list as started does not fill the floor.
#
# Run from anywhere: tests/fly-idle-reaper-lane-run.bh-6714-test.sh (exit 0 = all pass)
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

# ── L1. one machine, no floor row: the default floor 1 keeps it ─────────────
reset; machines lane-run "$(mach $M1 started)"; lr "$M1:0:0:5000"
run; run $((NOW + 3601))
[ "$RC" = 0 ] && ok || bad "L1 rc $RC: $OUT"
[ "$(stops)" = 0 ] && ok || bad "L1 the only lane-run machine was stopped: $(cat "$FIX/fly-calls")"
[ "$(row $M1 idle_state)" = exempt ] && ok || bad "L1 the floor row is '$(row $M1 idle_state)', want exempt"
[ "$(row $M1 source)" = lane-run ] && ok || bad "L1 the row source is '$(row $M1 source)', want lane-run"
[ "$(row $M1 idle_s)" = 5000 ] && ok || bad "L1 the row idle_s is '$(row $M1 idle_s)', want 5000"
[ "$(row $M1 threshold_s)" = null ] && ok || bad "L1 the floor row threshold_s is '$(row $M1 threshold_s)', want null"
[ "$(nalert 'id fly-idle-nosignal-lane-run')" = 0 ] && ok || bad "L1 fly-idle-nosignal-lane-run fired: $(cat "$FIX/alert-calls" 2>/dev/null)"
case "$(lastpass)" in *" floor=1") ok ;; *) bad "L1 the pass line does not end floor=1: $(lastpass)" ;; esac

# ── L2. floor 1 of three: the two most idle are stopped ─────────────────────
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)" "$(mach $M3 started)"
lr "$M1:0:0:5000" "$M2:0:0:2000" "$M3:0:0:100"
run
[ "$RC" = 0 ] && ok || bad "L2 rc $RC: $OUT"
stopped $M1 && ok || bad "L2 the 5000 s machine was not stopped: $(cat "$FIX/fly-calls")"
stopped $M2 && ok || bad "L2 the 2000 s machine was not stopped: $(cat "$FIX/fly-calls")"
stopped $M3 && bad "L2 the 100 s floor machine was stopped" || ok
grep -q destroy "$ALL" && bad "L2 a flyctl call destroyed something: $(grep destroy "$ALL")" || ok
[ "$(row $M3 idle_state)" = exempt ] && ok || bad "L2 the floor row is '$(row $M3 idle_state)', want exempt"
[ "$(row $M1 idle_state)" = stopping ] && ok || bad "L2 the 5000 s row is '$(row $M1 idle_state)', want stopping"
P=$(postrows)
[ "$(printf '%s\n' "$P" | grep -c .)" = 2 ] && ok || bad "L2 want 2 stop rows posted, got: $P"
[ "$(printf '%s\n' "$P" | jq -r 'select(.source == "lane-run" and .app == "lane-run" and .threshold_s == 900) | "\(.machine_id)=\(.idle_s)"' | sort | paste -sd,)" = "$M1=5000,$M2=2000" ] \
  && ok || bad "L2 the stop rows are wrong: $P"
[ "$(printf '%s\n' "$P" | jq -r '.source' | grep -cvE '^[a-z-]{1,32}$')" = 0 ] && ok || bad "L2 a stop row source fails the worker's ^[a-z-]{1,32}\$"
grep -q "lane-run/$M1: stopped after 5000s idle (.*source lane-run)" "$H/logs/fly-idle-reaper.log" && ok \
  || bad "L2 the stop log line does not name source lane-run: $(grep 'stopped after' "$H/logs/fly-idle-reaper.log")"
case "$(lastpass)" in *"stopping=2 "*" floor=1") ok ;; *) bad "L2 the pass line: $(lastpass)" ;; esac

# ── L3. busy and in_flight are busy; floor 0 stops nothing busy ─────────────
reset; floor 0
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"
lr "$M1:1:0:0" "$M2:0:1:120"
run
[ "$(stops)" = 0 ] && ok || bad "L3 a busy or in_flight machine was stopped: $(cat "$FIX/fly-calls")"
[ "$(row $M1 idle_state)" = busy ] && ok || bad "L3 the busy row is '$(row $M1 idle_state)', want busy"
[ "$(row $M2 idle_state)" = busy ] && ok || bad "L3 the in_flight row is '$(row $M2 idle_state)', want busy"
case "$(lastpass)" in *"busy=2 "*" floor=0") ok ;; *) bad "L3 the pass line: $(lastpass)" ;; esac
# L3b. a busy machine ranks first, so it fills a floor of 1.
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"
lr "$M1:1:0:0" "$M2:0:0:5000"
run
stopped $M2 && ok || bad "L3b the 5000 s machine was not stopped although the busy one fills the floor"
stopped $M1 && bad "L3b the busy machine was stopped" || ok
[ "$(row $M1 idle_state)" = busy ] && ok || bad "L3b the busy row is '$(row $M1 idle_state)', want busy"
case "$(lastpass)" in *" floor=0") ok ;; *) bad "L3b the pass line does not end floor=0: $(lastpass)" ;; esac
# L3c. an in_flight machine ranks first even with a higher idle_s than an idle
# one, so it fills a floor of 1 and the idle machine is not kept.
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"
lr "$M1:0:1:120" "$M2:0:0:100"
run
[ "$(row $M1 idle_state),$(row $M2 idle_state)" = "busy,idle" ] && ok || bad "L3c rows: $(row $M1 idle_state),$(row $M2 idle_state), want busy,idle"
case "$(lastpass)" in *" floor=0") ok ;; *) bad "L3c the pass line does not end floor=0: $(lastpass)" ;; esac

# ── L4. an unreadable answer: unknown, alert at the third pass, resolve ─────
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"
lr "$M1:0:0:5000" "$M2:0:0:5000"; : > "$FIX/lr-fail"
for p in 1 2 3; do
  run $((NOW + p * 300))
  [ "$(stops)" = 0 ] && ok || bad "L4 pass $p stopped a machine on an unreadable answer"
  [ "$(row $M1 idle_state),$(row $M2 idle_state)" = "unknown,unknown" ] && ok || bad "L4 pass $p rows: $(row $M1 idle_state),$(row $M2 idle_state)"
  [ "$(nlog 'lane-run: /api/lane-fleet/machines unreadable')" = "$p" ] && ok \
    || bad "L4 pass $p: want $p unreadable lines, got $(nlog 'lane-run: /api/lane-fleet/machines unreadable')"
  [ "$(cat "$H/state/fly-idle-reaper/fail/lane-run__$M1" 2>/dev/null)" = "$p" ] && ok || bad "L4 pass $p fail count: $(cat "$H/state/fly-idle-reaper/fail/lane-run__$M1" 2>/dev/null)"
  [ "$p" = 2 ] && { [ "$(nalert 'id fly-idle-fail-lane-run')" = 0 ] && ok || bad "L4 fly-idle-fail-lane-run fired after 2 passes"; }
done
[ "$(nlog "lane-run/$M1:")" = 0 ] && ok || bad "L4 a per-machine log line was written on a failed read"
[ "$(nalert 'id fly-idle-fail-lane-run')" = 1 ] && ok || bad "L4 fly-idle-fail-lane-run did not fire once after 3 passes: $(cat "$FIX/alert-calls" 2>/dev/null)"
rm -f "$FIX/lr-fail"; run $((NOW + 1200))
[ "$(nalert '--resolve --id fly-idle-fail-lane-run')" = 1 ] && ok || bad "L4 a good read did not resolve fly-idle-fail-lane-run: $(cat "$FIX/alert-calls" 2>/dev/null)"
[ -e "$H/state/fly-idle-reaper/fail/lane-run__$M1" ] && bad "L4 the fail streak was not cleared on a good read" || ok

# ── L5. floor row 0 stops the last one; a floor row above 100 is 1 ──────────
reset; floor 0
machines lane-run "$(mach $M1 started)"; lr "$M1:0:0:1000"
run
stopped $M1 && ok || bad "L5 floor 0: the 1000 s machine was not stopped"
reset; floor 250
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M1:0:0:1000" "$M2:0:0:5000"
run
[ "$(stops)" = 1 ] && ok || bad "L5 floor 250 (out of range = 1): $(stops) stops, want 1"
stopped $M2 && ok || bad "L5 floor 250: the 5000 s machine was not stopped"
[ "$(row $M1 idle_state)" = exempt ] && ok || bad "L5 floor 250: the 1000 s row is '$(row $M1 idle_state)', want exempt"

# ── L6. an unreadable floor row: no stop ────────────────────────────────────
reset; : > "$FIX/settings-down/lane_fleet.warm_floor"
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M1:0:0:5000" "$M2:0:0:5000"
run
[ "$(stops)" = 0 ] && ok || bad "L6 an unreadable warm_floor still stopped"
[ "$(row $M1 idle_state)" = unknown ] && ok || bad "L6 the row is '$(row $M1 idle_state)', want unknown"
grep -q 'lane-run: /api/lane-fleet/machines unreadable (.*warm_floor' "$H/logs/fly-idle-reaper.log" && ok \
  || bad "L6 the unreadable line does not name warm_floor: $(cat "$H/logs/fly-idle-reaper.log")"
# L6b. a floor row that is not an integer is unreadable too.
reset; floor abc
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M1:0:0:5000" "$M2:0:0:5000"
run
[ "$(stops)" = 0 ] && ok || bad "L6b a non-integer warm_floor still stopped"

# ── L7. incomplete: true is a failed read ───────────────────────────────────
reset; floor 0
machines lane-run "$(mach $M1 started)"; LR_INCOMPLETE=1 lr "$M1:0:0:5000"
run
[ "$(stops)" = 0 ] && ok || bad "L7 an incomplete answer still stopped"
[ "$(row $M1 idle_state)" = unknown ] && ok || bad "L7 the row is '$(row $M1 idle_state)', want unknown"
grep -q 'unreadable (.*incomplete' "$H/logs/fly-idle-reaper.log" && ok || bad "L7 the unreadable line does not say incomplete"
# L7b. an answer with no machines array is a failed read.
reset; floor 0
machines lane-run "$(mach $M1 started)"; echo '{"error":"x"}' > "$FIX/lr.json"
run
[ "$(stops)" = 0 ] && ok || bad "L7b an answer with no machines array still stopped"
[ "$(row $M1 idle_state)" = unknown ] && ok || bad "L7b the row is '$(row $M1 idle_state)', want unknown"

# ── L8. a started machine with no record row is unknown ─────────────────────
reset; floor 0
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M2:0:0:5000"
run
stopped $M1 && bad "L8 the machine with no lane_machines row was stopped" || ok
[ "$(row $M1 idle_state)" = unknown ] && ok || bad "L8 the row is '$(row $M1 idle_state)', want unknown"
grep -q "lane-run/$M1: no lane_machines row" "$H/logs/fly-idle-reaper.log" && ok || bad "L8 no log line for the unadopted machine"
stopped $M2 && ok || bad "L8 the other machine (with a row) was not stopped"
# L8b. a row with no idle_s is unknown.
reset; floor 0
machines lane-run "$(mach $M1 started)"; lr "$M1:0:0:-"
run
[ "$(stops)" = 0 ] && ok || bad "L8b a row with no idle_s was stopped"
[ "$(row $M1 idle_state)" = unknown ] && ok || bad "L8b the row is '$(row $M1 idle_state)', want unknown"

# ── L9. the per-pass stop cap counts lane-run stops ─────────────────────────
reset; floor 0; echo 1 > "$FIX/settings/fly.idle_max_stops_per_pass"
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M1:0:0:5000" "$M2:0:0:5000"
run
[ "$(stops)" = 1 ] && ok || bad "L9 cap 1: $(stops) stops"
[ "$(row $M1 idle_state),$(row $M2 idle_state)" = "stopping,over" ] && ok || bad "L9 rows: $(row $M1 idle_state),$(row $M2 idle_state)"

# ── L10. an old nosignal condition for lane-run is resolved ─────────────────
reset; floor 1
mkdir -p "$H/state/fly-idle-reaper/fired" "$H/state/fly-idle-reaper/nosignal"
: > "$H/state/fly-idle-reaper/fired/fly-idle-nosignal-lane-run"; echo $((NOW - 7200)) > "$H/state/fly-idle-reaper/nosignal/lane-run"
machines lane-run "$(mach $M1 started)"; lr "$M1:0:0:5000"
run
[ "$(nalert '--resolve --id fly-idle-nosignal-lane-run')" = 1 ] && ok || bad "L10 fly-idle-nosignal-lane-run was not resolved: $(cat "$FIX/alert-calls" 2>/dev/null)"

# ── L11. edges: the floor beats the threshold; 900 s is not over 900 ────────
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 started)"; lr "$M1:0:0:5000" "$M2:0:0:901"
run
stopped $M1 && ok || bad "L11 the 5000 s machine was not stopped"
stopped $M2 && bad "L11 the 901 s floor machine was stopped" || ok
[ "$(row $M2 idle_state)" = exempt ] && ok || bad "L11 the 901 s row is '$(row $M2 idle_state)', want exempt"
reset; floor 0
machines lane-run "$(mach $M1 started)"; lr "$M1:0:0:900"
run
[ "$(stops)" = 0 ] && ok || bad "L11b the 900 s machine was stopped"
[ "$(row $M1 idle_state)" = idle ] && ok || bad "L11b the row is '$(row $M1 idle_state)', want idle"

# ── L12. no started lane-run machine: no read ───────────────────────────────
reset; floor 0
machines lane-run "$(mach $M1 stopped)"; lr "$M1:0:0:5000"
run
grep -q '^GET /api/lane-fleet/machines' "$FIX/jobs-calls" && bad "L12 the lane-fleet answer was read with no started lane-run machine" || ok

# ── L13. the token stays out of logs, rows and requests ─────────────────────
grep -rq 'fm2_fixture' "$H/logs" "$H/state" "$FIX/jobs-calls" "$FIX/alert-calls" 2>/dev/null \
  && bad "L13 the token value is in a log, a state file, a jobs request or an alert" || ok

# ── L14. a record row Fly does not list as started does not fill the floor ──
reset; floor 1
machines lane-run "$(mach $M1 started)" "$(mach $M2 stopped)"; lr "$M1:0:0:5000" "$M2:1:0:0"
run
[ "$(stops)" = 0 ] && ok || bad "L14 the only started machine was stopped: a stopped machine's row filled the floor"
[ "$(row $M1 idle_state)" = exempt ] && ok || bad "L14 the row is '$(row $M1 idle_state)', want exempt"

echo "fly-idle-reaper-lane-run: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
