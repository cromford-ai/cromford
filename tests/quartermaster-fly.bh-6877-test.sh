#!/bin/bash
# tests/quartermaster-fly.bh-6877-test.sh — Quartermaster sees each Fly machine
# the idle reaper could not settle, and acts on it only through
# `bin/fly-idle-reaper.sh act` (BH-6877).
#
#   Q1  a GET /api/fly-idle fixture with one nosignal machine -> the collector
#       prints one fly-unsettled line; on a registered metrics app `act probe`
#       then `act stop` -> two machine execs, one stop row, one fly_idle_action beat with $/h
#   Q2  `act stop` with flyctl rc 1 -> rc 1, no row, no beat
#   Q3  `act stop` on an exempt app is refused: rc 1, no flyctl stop
#   Q4  `act keep` writes one log line and no row; bad usage is rc 2
#   Q5  the fly-idle read fails -> the cost findings still print, rc 0
#   Q6  `act destroy` follows the pass's destroy rule (source, 7 days); a
#       recorded builder (state/fly/<p>.json machine_id) or a machine with a
#       mounted volume is refused
#   Q7  `act stop` enforces the probe in code: a pool machine the probe calls
#       busy or unknown, a lane-run machine whose lane record is busy or
#       missing, and any stop while a settings row is unreadable are refused
#   Q8  `act stop` on an app with no registry entry is refused with one log
#       line and one alert (no probe, no stop); a registered metrics app is
#       probed, and a failed probe refuses the stop
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/quartermaster-fly.bh-6877-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
command -v jq >/dev/null 2>&1 || { echo "quartermaster-fly: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "quartermaster-fly: python3 is required"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
n_of() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

# 2026-10-14T12:00:00Z, pinned (D60).
NOW=1791979200
M1=1f1d000000e1; M2=1f1d000000e2; M3=1f1d000000e3
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/bin" "$H/catalog" "$H/logs" "$H/env" "$H/locks" "$FXT" "$T/fakebin" "$T/home"

# ═════ the collector ═════════════════════════════════════════════════════════
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure bin/jobs-client.sh"
scratch_install_closure bin/staff/quartermaster-collect.sh "$H" >/dev/null || bad "closure bin/staff/quartermaster-collect.sh"
cat > "$T/qmfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/metrics/cost-rows?"*) echo '{"cost_rows":[]}'; return 0 ;;
    "GET /api/fly-idle") [ -f "$FXT/fly.fail" ] && return 1; cat "$FXT/fly-idle.json"; return 0 ;;
  esac
  return 1
}
SH
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"
done
# The GET /api/fly-idle body (worker/jobs/src/routes/fly-idle.js): one nosignal,
# one busy, one idle machine.
jq -nc --arg a "$M1" --arg b "$M2" --arg c "$M3" '{
  pass: {pass_at: "2026-10-14T11:57:00Z", apps_total: 3, apps_failed: 0, partial: 0, box: "fixture"},
  machines: [
    {app: "mystery-app", machine_id: $a, size: "performance-16x", source: "metrics", idle_s: null, idle_state: "nosignal",
     threshold_s: null, usd_per_hour: 0.89863, last_work_at: null, no_claim: null},
    {app: "pool-cromford", machine_id: $b, size: "performance-16x", source: "pool", idle_s: 0, idle_state: "busy",
     threshold_s: 900, usd_per_hour: 0.89863, last_work_at: "2026-10-14T11:57:00Z", no_claim: null},
    {app: "pool-cromford", machine_id: $c, size: "performance-16x", source: "pool", idle_s: 300, idle_state: "idle",
     threshold_s: 900, usd_per_hour: 0.89863, last_work_at: null, no_claim: null}],
  over_count: 0, stops: [], stops_24h: 0, destroys: [], destroys_24h: 0}' > "$FXT/fly-idle.json"
qm() {
  env HARNESS="$H" FXT="$FXT" QM_FIXTURE="$T/qmfx.sh" HARNESS_TEST_SANDBOX=1 QM_NOW="$NOW" QM_READ_EVERY_S=0 \
    LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= PATH="$T/fakebin:$PATH" bash "$H/bin/staff/quartermaster-collect.sh" > "$T/out" 2> "$T/err"
  RC=$?
}
qm
eq "Q1 collector rc" "$RC" 0
eq "Q1 fly-unsettled lines" "$(n_of '"class":"fly-unsettled"' "$T/out")" 1
eq "Q1 the finding names the machine" "$(jq -r 'select(.class == "fly-unsettled") | .item.machine_id' "$T/out" 2>/dev/null)" "$M1"
eq "Q1 the item state" "$(jq -r 'select(.class == "fly-unsettled") | .item.state' "$T/out" 2>/dev/null)" nosignal
case "$(jq -r 'select(.class == "fly-unsettled") | .title' "$T/out" 2>/dev/null)" in
  *"mystery-app/$M1"*"act probe mystery-app $M1"*) ok ;;
  *) bad "Q1 the title does not name the machine and the act command: $(cat "$T/out")" ;;
esac
eq "Q1 the source" "$(jq -r 'select(.class == "fly-unsettled") | .source.kind + " " + .source.url' "$T/out" 2>/dev/null)" "fly_idle /machines"
# A no-claim lane-run machine and an unknown one are unsettled too; idle is not.
jq -c --arg a "$M2" '.machines[1].idle_state = "unknown" | .machines[2].no_claim = true | .machines[2].app = "lane-run"' \
  "$FXT/fly-idle.json" > "$FXT/f2" && mv "$FXT/f2" "$FXT/fly-idle.json"
qm
eq "Q1b unsettled lines (nosignal, unknown, no-claim)" "$(n_of '"class":"fly-unsettled"' "$T/out")" 3
eq "Q1b no-claim state" "$(jq -r "select(.item.machine_id == \"$M3\") | .item.state" "$T/out" 2>/dev/null)" no-claim
# Q5: the fly-idle read fails: no fly line, rc 0.
touch "$FXT/fly.fail"; qm
eq "Q5 rc" "$RC" 0
eq "Q5 no fly lines" "$(n_of fly-unsettled "$T/out")" 0
rm -f "$FXT/fly.fail"

# ═════ the act verb, against the real reaper ═════════════════════════════════
FIX="$T/fix"; mkdir -p "$FIX/settings"
cat > "$H/bin/jobs-client.sh" <<'STUB'
_jobs_box_name() { echo fixture; }
setting_get() { [ -f "$FIX/settings-down/$1" ] && return 1; [ -f "$FIX/settings/$1" ] || return 2; cat "$FIX/settings/$1"; }
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FIX/jobs-calls"
  case "$1 $2" in
    "GET /api/lane-fleet/machines") [ -f "$FIX/lane.json" ] || return 1; cat "$FIX/lane.json" ;;
    "POST /api/fly-idle/stops"|"POST /api/fly-idle/destroys") echo '{"inserted":1,"ignored":0}' ;;
    *) return 1 ;;
  esac
}
STUB
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
STUB
cat > "$H/bin/beat.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$FIX/beats"
STUB
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 $2" in
  "machine list") cat "$FIX/m-$4.json" 2>/dev/null || exit 1 ;;
  "machine exec") cat "$FIX/exec-out" 2>/dev/null || printf '  0.0 /.fly/init\n  0.0 sleep infinity\n' ;;
  "machine stop") exit "$(cat "$FIX/stop-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
chmod +x "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$T/fakebin/flyctl"
scratch_install_closure bin/fly-idle-reaper.sh "$H" >/dev/null || bad "closure bin/fly-idle-reaper.sh"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cp "$DIR/catalog/fly-idle-signals.json" "$DIR/catalog/fly-prices.json" "$DIR/catalog/fly-work-procs.json" "$H/catalog/"
printf 'FLY_API_TOKEN="FlyV1 fm2_fixture"\n' > "$H/env/fly.env"; : > "$H/env/global.env"
jq -nc --arg id "$M1" --argjson s $((NOW - 7200)) '[{id:$id, state:"started",
  config:{guest:{cpu_kind:"performance", cpus:16, memory_mb:32768}},
  events:[{type:"start", status:"started", timestamp:($s*1000)}]}]' > "$FIX/m-mystery-app.json"
cp "$FIX/m-mystery-app.json" "$FIX/m-bh-ci-runners-example-org.json"
# TEST-CHANGE (lead review BLOCK on 83ca230c): `act stop` now refuses an app with
# no registry entry (mystery-app, Q8). The stop flow of Q1/Q2 runs on a
# registered metrics app, and its probe is one more `machine exec`.
cp "$FIX/m-mystery-app.json" "$FIX/m-project-12-joy-lab.json"
export FIX
act() { # act <args...> -> OUT, RC
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin" HOME="$T/home" HARNESS="$H" FIX="$FIX" FLY_IDLE_REAPER_NOW="$NOW" \
    bash "$H/bin/fly-idle-reaper.sh" act "$@" 2>&1 </dev/null); RC=$?
}
act probe project-12-joy-lab "$M1"
eq "Q1 act probe rc" "$RC" 0
case "$OUT" in *idle*) ok ;; *) bad "Q1 act probe did not print idle: $OUT" ;; esac
act stop project-12-joy-lab "$M1" "probe shows only the init process and sleep"
eq "Q1 act stop rc" "$RC" 0
eq "Q1 machine exec calls (act probe, then the probe inside act stop)" "$(n_of '^machine exec' "$FIX/fly-calls")" 2
eq "Q1 machine stop calls" "$(n_of "^machine stop $M1 -a project-12-joy-lab" "$FIX/fly-calls")" 1
eq "Q1 stop rows" "$(n_of '^POST /api/fly-idle/stops' "$FIX/jobs-calls")" 1
ROW=$(grep '^POST /api/fly-idle/stops ' "$FIX/jobs-calls" | head -n 1 | cut -d' ' -f3-)
eq "Q1 the row machine" "$(printf '%s' "$ROW" | jq -r '.rows[0].machine_id')" "$M1"
eq "Q1 the row source" "$(printf '%s' "$ROW" | jq -r '.rows[0].source')" act
eq "Q1 the row idle_s (since the start event)" "$(printf '%s' "$ROW" | jq -r '.rows[0].idle_s')" 7200
eq "Q1 beats" "$(n_of . "$FIX/beats")" 1
eq "Q1 beat kind" "$(jq -r .kind "$FIX/beats" 2>/dev/null)" fly_idle_action
case "$(jq -r .detail "$FIX/beats" 2>/dev/null)" in
  *'$'[0-9]*'/h'*) ok ;; *) bad "Q1 the beat does not carry \$/h: $(cat "$FIX/beats")" ;; esac
[ "$(jq -r .usd_per_hour "$FIX/beats" 2>/dev/null)" = "$(printf '%s' "$ROW" | jq -r '.rows[0].usd_per_hour')" ] && ok \
  || bad "Q1 the beat usd_per_hour is not the row's"
grep -q "act stop project-12-joy-lab/$M1" "$H/logs/fly-idle-reaper.log" && ok || bad "Q1 act stop wrote no log line"

# Q2: flyctl stop fails.
: > "$FIX/jobs-calls"; : > "$FIX/beats"; echo 1 > "$FIX/stop-rc"
act stop project-12-joy-lab "$M1" "retry"
eq "Q2 rc" "$RC" 1
eq "Q2 stop rows" "$(n_of '^POST /api/fly-idle/stops' "$FIX/jobs-calls")" 0
eq "Q2 beats" "$(n_of . "$FIX/beats")" 0
rm -f "$FIX/stop-rc"

# Q8: an app with no registry entry is never stopped by hand: one refusal log
# line, one alert, no probe and no stop. A registered metrics app whose probe
# fails (no ps in the image) is refused too.
: > "$FIX/fly-calls"; : > "$FIX/jobs-calls"; : > "$FIX/beats"; : > "$FIX/alert-calls"
act stop mystery-app "$M1" "metrics look quiet"
eq "Q8 unregistered app: rc" "$RC" 1
eq "Q8 unregistered app: no machine stop" "$(n_of '^machine stop' "$FIX/fly-calls")" 0
eq "Q8 unregistered app: no probe" "$(n_of '^machine exec' "$FIX/fly-calls")" 0
eq "Q8 unregistered app: no stop row" "$(n_of '^POST /api/fly-idle/stops' "$FIX/jobs-calls")" 0
eq "Q8 unregistered app: no beat" "$(n_of . "$FIX/beats")" 0
eq "Q8 unregistered app: one alert with its id" "$(n_of '--id fly-idle-act-unregistered-mystery-app' "$FIX/alert-calls")" 1
grep -q "act stop mystery-app/$M1 refused: mystery-app has no entry in catalog/fly-idle-signals.json" "$H/logs/fly-idle-reaper.log" \
  && ok || bad "Q8 no refusal log line: $(tail -3 "$H/logs/fly-idle-reaper.log")"
case "$OUT" in *"refused: mystery-app has no registry entry"*) ok ;; *) bad "Q8 the answer does not say why: $OUT" ;; esac
printf 'Error: exec: "ps": executable file not found in $PATH\n' > "$FIX/exec-out"
act stop project-12-joy-lab "$M1" "metrics look quiet"
eq "Q8 metrics app, failed probe: rc" "$RC" 1
eq "Q8 metrics app, failed probe: one probe" "$(n_of '^machine exec' "$FIX/fly-calls")" 1
eq "Q8 metrics app, failed probe: no machine stop" "$(n_of '^machine stop' "$FIX/fly-calls")" 0
rm -f "$FIX/exec-out"

# Q3: exempt is refused before any Fly write.
: > "$FIX/fly-calls"
act stop bh-ci-runners-example-org "$M1" "test"
eq "Q3 rc" "$RC" 1
eq "Q3 stop calls" "$(n_of '^machine stop' "$FIX/fly-calls")" 0

# Q6: act destroy — a stopped pool machine past the rule is destroyed once, with
# a row and a beat; a metrics app or a 6-day stop is refused.
stopped_json() { jq -nc --arg id "$M1" --argjson x "$1" '[{id:$id, state:"stopped",
  config:{guest:{cpu_kind:"performance", cpus:16, memory_mb:32768}},
  events:[{type:"exit", status:"stopped", timestamp:($x*1000)}]}]'; }
stopped_json $((NOW - 691200)) > "$FIX/m-pool-cromford.json"
stopped_json $((NOW - 2592000)) > "$FIX/m-mystery-app.json"
: > "$FIX/fly-calls"; : > "$FIX/jobs-calls"; : > "$FIX/beats"
act destroy mystery-app "$M1" "long stopped"
eq "Q6 a metrics app destroy rc" "$RC" 1
act destroy pool-cromford "$M1" "stopped 8 days"
eq "Q6 pool destroy rc" "$RC" 0
eq "Q6 destroy calls" "$(n_of '^machine destroy' "$FIX/fly-calls")" 1
eq "Q6 destroy rows" "$(n_of '^POST /api/fly-idle/destroys' "$FIX/jobs-calls")" 1
eq "Q6 destroy beat" "$(jq -r .action "$FIX/beats" 2>/dev/null)" destroy
stopped_json $((NOW - 518400)) > "$FIX/m-pool-cromford.json"
act destroy pool-cromford "$M1" "stopped 6 days"
eq "Q6 a 6-day stop is refused" "$RC" 1
eq "Q6 still one destroy call" "$(n_of '^machine destroy' "$FIX/fly-calls")" 1

# Q6b: the recorded persistent builder of a project, and any machine with a
# mounted volume, is never destroyed: only fly-provision.sh makes them again.
stopped_json $((NOW - 691200)) > "$FIX/m-builder-acme.json"
mkdir -p "$H/state/fly"; printf '{"app":"builder-acme","machine_id":"%s","volume_id":"vol_x"}\n' "$M1" > "$H/state/fly/acme.json"
: > "$FIX/fly-calls"
act destroy builder-acme "$M1" "stopped 8 days"
eq "Q6b a recorded builder destroy rc" "$RC" 1
eq "Q6b recorded builder destroy calls" "$(n_of '^machine destroy' "$FIX/fly-calls")" 0
grep -q "act destroy builder-acme/$M1 refused.*recorded builder" "$H/logs/fly-idle-reaper.log" && ok || bad "Q6b the refusal does not name the record"
rm -f "$H/state/fly/acme.json"
jq '.[0].config.mounts = [{volume: "vol_y", path: "/data"}]' "$FIX/m-builder-acme.json" > "$FIX/m.tmp" && mv "$FIX/m.tmp" "$FIX/m-builder-acme.json"
act destroy builder-acme "$M1" "stopped 8 days"
eq "Q6b a mounted-volume destroy rc" "$RC" 1
eq "Q6b mounted-volume destroy calls" "$(n_of '^machine destroy' "$FIX/fly-calls")" 0

# Q7: act stop probes first, in code. A pool machine: busy and unknown refuse.
started_json() { jq -nc --arg id "$M1" --argjson s $((NOW - 7200)) '[{id:$id, state:"started",
  config:{guest:{cpu_kind:"performance", cpus:16, memory_mb:32768}},
  events:[{type:"start", status:"started", timestamp:($s*1000)}]}]'; }
started_json > "$FIX/m-pool-cromford.json"; started_json > "$FIX/m-lane-run.json"
: > "$FIX/fly-calls"; : > "$FIX/jobs-calls"
printf '  0.0 /.fly/init\n 40.0 /bin/bash /root/harness/bin/run-build.sh acme X-1\n' > "$FIX/exec-out"
act stop pool-cromford "$M1" "looks idle"
eq "Q7 a busy probe refuses the stop" "$RC" 1
printf 'Error: no such command\n' > "$FIX/exec-out"
act stop pool-cromford "$M1" "looks idle"
eq "Q7 an unknown probe refuses the stop" "$RC" 1
eq "Q7 probes ran" "$(n_of '^machine exec' "$FIX/fly-calls")" 2
eq "Q7 no stop on busy or unknown" "$(n_of '^machine stop' "$FIX/fly-calls")" 0
eq "Q7 no stop rows" "$(n_of '^POST /api/fly-idle/stops' "$FIX/jobs-calls")" 0
rm -f "$FIX/exec-out"
act stop pool-cromford "$M1" "probe idle"
eq "Q7 an idle probe stops" "$RC" 0
eq "Q7 one stop" "$(n_of "^machine stop $M1 -a pool-cromford" "$FIX/fly-calls")" 1
# lane-run: no lane record, then a busy one, refuse before the probe.
: > "$FIX/fly-calls"
act stop lane-run "$M1" "idle"
eq "Q7 lane-run with no lane record" "$RC" 1
lrec() { jq -nc --arg id "$M1" --argjson b "$1" '{machines:[{machine_id:$id, state:"running", started_at:"2026-10-14T10:00:00Z",
  busy:$b, in_flight:false, idle_s:7200}], incomplete:false}' > "$FIX/lane.json"; }
lrec true
act stop lane-run "$M1" "idle"
eq "Q7 lane-run busy in its lane record" "$RC" 1
eq "Q7 no lane-run stop or probe" "$(n_of '^machine \(stop\|exec\)' "$FIX/fly-calls")" 0
lrec false
act stop lane-run "$M1" "idle"
eq "Q7 lane-run idle record and idle probe stops" "$RC" 0
# An unreadable settings row: no stop at all.
started_json > "$FIX/m-pool-cromford.json"; : > "$FIX/fly-calls"
mkdir -p "$FIX/settings-down"; : > "$FIX/settings-down/fly.idle_stop_after_s"
act stop pool-cromford "$M1" "idle"
eq "Q7 nostop refuses the stop" "$RC" 1
eq "Q7 nostop: no flyctl stop" "$(n_of '^machine stop' "$FIX/fly-calls")" 0
rm -f "$FIX/settings-down/fly.idle_stop_after_s"

# Q4: keep and usage.
: > "$FIX/jobs-calls"
act keep mystery-app "$M1" "customer demo until Friday"
eq "Q4 keep rc" "$RC" 0
grep -q "act keep mystery-app/$M1: customer demo until Friday" "$H/logs/fly-idle-reaper.log" && ok || bad "Q4 keep wrote no log line"
eq "Q4 keep rows" "$(n_of '^POST' "$FIX/jobs-calls")" 0
act keep mystery-app "$M1"
eq "Q4 keep without a reason" "$RC" 2
act explode mystery-app "$M1"
eq "Q4 an unknown action" "$RC" 2
act stop "Bad App" "$M1" "x"
eq "Q4 a bad app name" "$RC" 2

echo "quartermaster-fly: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
