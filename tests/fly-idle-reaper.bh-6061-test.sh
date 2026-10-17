#!/bin/bash
# tests/fly-idle-reaper.bh-6061-test.sh — the Fly idle reaper stops what is
# idle, never what it cannot read, and never destroys a machine stopped for
# less than fly.destroy_after_stopped_s (BH-6061; the destroy step is BH-6877).
#
# WHAT THIS PINS. The REAL bin/fly-idle-reaper.sh, installed with its closure
# into a scratch $HARNESS, against a flyctl stub on PATH (apps and machines from
# fixtures, every call recorded), a jobs-client stub (settings from files, the
# claimed queue from a fixture, every request recorded), a lane-alert recorder
# and a testhost-tick.sh stub. One fixed clock for the whole file.
#   R1/R2/R2b the threshold is "above": 1000 s stops, 600 s and 900 s do not;
#   R3  a pool tracking file or a claimed queue row is busy;
#   R4  the summary line counts what was listed;
#   R5  an app with no signal is never stopped and alerts once after 1 h;
#   R6  an unreadable queue is unknown, never idle, and alerts after 3 passes;
#   R7  a stop writes its row, and the row is the worker test's fixture;
#   R8  the per-pass stop cap;   R9  a failed stop writes no row;
#   R10 no state/fly-pool is unknown;   R11 the lane-off flag;   R12 testhost;
#   R13 the lock;   R14 settings;   R15 exempt;   R16 no destroy under 7 d;
#   R17 the outbox;   R18 the token stays out of logs and rows;
#   R19 no token / no flyctl / apps list failure.
#
# Run from anywhere: tests/fly-idle-reaper.bh-6061-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$DIR/bin/fly-idle-reaper.sh" ] || { echo "FAIL: bin/fly-idle-reaper.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Every file this ticket adds exists (the slices ship together).
for f in bin/fly-idle-reaper.sh bin/lib/fly-bin.sh catalog/fly-idle-signals.json \
  catalog/lanes.d/fly-idle-reaper.json cron/lanes/729-fly-idle-reaper.cron \
  worker/jobs/src/routes/fly-idle.js worker/jobs/schema.d/0023-bh-6061-fly-idle.sql \
  worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json worker/jobs/test/fly-idle.bh-6061.test.js \
  worker/jobs/test/route-table.d/748-fly-idle.txt console-ui/tests/fly-idle.bh-6061.test.js \
  console-ui/src/lib/fly-idle.js console-ui/src/screens/FlyIdlePanel.js; do
  [ -f "$DIR/$f" ] && ok || bad "missing $f"
done

# One clock for the whole file (2026-10-11T06:26:40Z).
NOW=1791700000
FIX="$T/fix"; H="$T/h"; ALL="$T/all-fly-calls"
P1=1f1d00000001; B1=1f1d000000b1; T1=1f1d000000c1; X1=1f1d000000e1

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
    "GET /api/queue"*) [ -f "$FIX/queue-fail" ] && return 1; cat "$FIX/queue.json" ;;
    "POST /api/fly-idle/stops") [ -f "$FIX/post-fail" ] && return 1; echo '{"inserted":1,"ignored":0}' ;;
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
echo "$* app=${TESTHOST_APP:-}" >> "$FIX/th-calls"
cat "$FIX/th-out" 2>/dev/null
exit "$(cat "$FIX/th-rc" 2>/dev/null || echo 0)"
STUB
  cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"; echo "$*" >> "$ALL"
[ "${FLY_ACCESS_TOKEN:-}" = "FlyV1 fm2_fixture" ] || echo "no-token $*" >> "$FIX/fly-calls"
case "$1 $2" in
  "apps list") [ -f "$FIX/apps-fail" ] && { echo "Error: server error (token FlyV1 fm2_fixture)" >&2; exit 1; }
               cat "$FIX/apps.json" ;;
  "machine list") cat "$FIX/m-$4.json" 2>/dev/null || { echo "Error: app not found" >&2; exit 1; } ;;
  "machine stop") exit "$(cat "$FIX/stop-rc" 2>/dev/null || echo 0)" ;;
  "machine exec") printf '  0.0 /.fly/init\n  0.0 sleep infinity\n' ;;
esac
exit 0
STUB
  chmod +x "$H/bin/lane-alert.sh" "$H/bin/testhost-tick.sh" "$T/fakebin/flyctl"
  scratch_install_closure bin/fly-idle-reaper.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
  cp "$(rendered_registry)" "$H/catalog/lanes.json"
  cp "$DIR/catalog/fly-idle-signals.json" "$DIR/catalog/fly-prices.json" "$DIR/catalog/fly-work-procs.json" "$H/catalog/"
}
stub_files
export FIX ALL

# mach <id> <state> <newest-epoch|-> [kind cpus mem] — one machine, flyctl shape.
# The newest event is the start (BH-6877: only start/launch events start idle).
mach() {
  jq -nc --arg id "$1" --arg st "$2" --arg s "$3" --arg k "${4:-performance}" \
    --argjson c "${5:-16}" --argjson m "${6:-32768}" '
    {id:$id, state:$st, config:{guest:{cpu_kind:$k, cpus:$c, memory_mb:$m}},
     events:(if $s == "-" then [] else
       [{type:"start", status:"started", timestamp:(($s|tonumber)*1000)},
        {type:"exit", status:"stopped", timestamp:((($s|tonumber)-60)*1000)}] end)}'
}
apps() { printf '%s\n' "$@" | jq -R '{Name: .}' | jq -sc . > "$FIX/apps.json"; }
machines() { local a="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$FIX/m-$a.json"; }
reset() {
  scratch_rm "$FIX" >/dev/null 2>&1 || true
  scratch_rm "$H/state" >/dev/null 2>&1 || true
  mkdir -p "$FIX/settings" "$FIX/settings-down" "$H/state/fly-pool/cromford" "$H/state/fly"
  rm -f "$H/logs/fly-idle-reaper.log" "$H/flags/lane-off-fly-idle-reaper"
  printf 'FLY_API_TOKEN="FlyV1 fm2_fixture"\n' > "$H/env/fly.env"; : > "$H/env/global.env"
  echo '{"queue":[]}' > "$FIX/queue.json"
  echo 0 > "$FIX/th-out"
  apps pool-cromford builder-project-5 bh-testhost-example-org
  machines pool-cromford "$(mach $P1 started $((NOW - 1000)))" "$(mach 1f1d000000a2 stopped $((NOW - 90000)))"
  machines builder-project-5 "$(mach $B1 started $((NOW - 100)))"
  machines bh-testhost-example-org "$(mach $T1 started $((NOW - 50000)))"
}
run() { # run [epoch]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin" HOME="$T/home" HARNESS="$H" FIX="$FIX" ALL="$ALL" \
    FLY_IDLE_REAPER_NOW="${1:-$NOW}" bash "$H/bin/fly-idle-reaper.sh" 2>&1 </dev/null); RC=$?
}
stops()  { grep -c '^machine stop' "$FIX/fly-calls" 2>/dev/null || true; }
stopped() { grep -q "^machine stop $1 -a $2" "$FIX/fly-calls" 2>/dev/null; }
row_state() { jq -r --arg m "$1" '.rows[] | select(.machine_id == $m) | .idle_state' "$FIX/last-put.json" 2>/dev/null; }
nalert() { local n; n=$(grep -c -- "$1" "$FIX/alert-calls" 2>/dev/null); echo "${n:-0}"; }
lastpass() { grep ' pass apps=' "$H/logs/fly-idle-reaper.log" 2>/dev/null | tail -n 1; }

# ── R1 / R7. over the threshold: stopped, and the row is written ───────────
reset; run
[ "$RC" = 0 ] && ok || bad "R1 rc $RC: $OUT"
stopped $P1 pool-cromford && ok || bad "R1 the 1000 s idle pool machine was not stopped: $(cat "$FIX/fly-calls")"
grep -q '^no-token' "$FIX/fly-calls" && bad "R1 a flyctl call had no FLY_ACCESS_TOKEN" || ok
[ "$(row_state $P1)" = stopping ] && ok || bad "R1 the snapshot row is '$(row_state $P1)', want stopping"
[ -z "$(ls -A "$H/state/fly-idle-reaper/outbox" 2>/dev/null)" ] && ok || bad "R7 the outbox is not empty after a good POST"
POST=$(grep '^POST /api/fly-idle/stops ' "$FIX/jobs-calls" | head -n 1 | cut -d' ' -f3-)
row() { printf '%s' "$POST" | jq -r ".rows[0].$1" 2>/dev/null; }
[ "$(row app)" = pool-cromford ] && [ "$(row machine_id)" = $P1 ] && [ "$(row size)" = performance-16x ] \
  && [ "$(row idle_s)" = 1000 ] && [ "$(row status)" = requested ] && [ "$(row threshold_s)" = 900 ] \
  && ok || bad "R7 the stop row is wrong: $POST"
want=$( . "$DIR/bin/lib/fly-cost-row.sh"; fly_price_per_s "$DIR/catalog/fly-prices.json" performance 16 32768 | awk '{printf "%.6f", $1 * 3600}')
[ "$(row usd_per_hour)" = "$want" ] && ok || bad "R7 usd_per_hour is '$(row usd_per_hour)', want $want (fly_price_per_s x 3600)"
# The round trip: the worker test POSTs this exact body.
# Numbers compare as numbers: jq keeps a literal's text (0.898630 vs 0.89863).
norm() { jq -S 'walk(if type == "number" then . + 0 else . end)' 2>/dev/null; }
if [ -n "$POST" ] && [ "$(printf '%s' "$POST" | norm)" = "$(norm < "$DIR/worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json")" ]; then ok
else bad "R7 worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json differs from the reaper's POST body: $POST"; fi

# ── R2 / R2b. at or under the threshold: not stopped ───────────────────────
reset; machines pool-cromford "$(mach $P1 started $((NOW - 600)))"; run
stopped $P1 pool-cromford && bad "R2 a 600 s idle machine was stopped" || ok
[ "$(row_state $P1)" = idle ] && ok || bad "R2 the row is '$(row_state $P1)', want idle"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 900)))"; run
stopped $P1 pool-cromford && bad "R2b idle == threshold (900 = 900) was stopped" || ok

# ── R3. a witness holds the machine: busy ──────────────────────────────────
reset; machines pool-cromford "$(mach $P1 started $((NOW - 10800)))"
echo '{}' > "$H/state/fly-pool/cromford/$P1.json"; run
stopped $P1 pool-cromford && bad "R3a a machine with a pool tracking file was stopped" || ok
[ "$(row_state $P1)" = busy ] && ok || bad "R3a the row is '$(row_state $P1)', want busy"
reset; machines pool-cromford "$(mach $P1 started $((NOW - 10800)))"
echo "{\"queue\":[{\"id\":\"j1\",\"machine\":\"$P1\"}]}" > "$FIX/queue.json"; run
stopped $P1 pool-cromford && bad "R3b a machine in a claimed queue row was stopped" || ok
[ "$(row_state $P1)" = busy ] && ok || bad "R3b the row is '$(row_state $P1)', want busy"
reset; machines builder-project-5 "$(mach $B1 started $((NOW - 5000)))"
echo "{\"machine_id\":\"$B1\"}" > "$H/state/fly/project-5.json"; echo '{}' > "$H/state/fly/project-5-active.json"; run
stopped $B1 builder-project-5 && bad "R3c a builder with an active dispatcher record was stopped" || ok
# BH-6877: the busy pass above stamped the last work time, so idle counts from it.
rm -f "$H/state/fly/project-5-active.json"; run $((NOW + 1000))
stopped $B1 builder-project-5 && ok || bad "R3d a builder whose dispatcher record is not active (1000 s after the last witness) was not stopped"

# ── R4. the summary line ───────────────────────────────────────────────────
reset; run
case "$(lastpass)" in
  *"apps=3 read=3 failed=0 partial=0 started=3 "*"stopping=1 "*"threshold=900(fallback) nostop=0"*) ok ;;
  *) bad "R4 the summary line is wrong: $(lastpass)" ;;
esac
[ "$(jq -r '.apps_total, .apps_failed' "$FIX/last-put.json" | paste -sd,)" = "3,0" ] && ok || bad "R4 the snapshot PUT apps counts: $(cat "$FIX/last-put.json")"

# ── R5. no signal: never stopped, one alert after 1 h, resolved when gone ──
reset; apps mystery-app pool xpool-foo
machines mystery-app "$(mach $X1 started $((NOW - 90000)))"
machines pool "$(mach 1f1d000000e2 started $((NOW - 90000)))"
machines xpool-foo "$(mach 1f1d000000e3 started $((NOW - 90000)))"
run
[ "$(stops)" = 0 ] && ok || bad "R5 a no-signal app (mystery-app, pool, xpool-foo) was stopped: $(cat "$FIX/fly-calls")"
[ "$(row_state 1f1d000000e2)" = nosignal ] && [ "$(row_state 1f1d000000e3)" = nosignal ] && ok || bad "R5 'pool' and 'xpool-foo' must be nosignal"
[ "$(nalert 'id fly-idle-nosignal-mystery-app ')" = 0 ] && ok || bad "R5 the first pass alerted"
run $((NOW + 3600))
[ "$(nalert 'severity warn --id fly-idle-nosignal-mystery-app ')" = 1 ] && ok || bad "R5 the pass at +1 h sent $(nalert 'severity warn --id fly-idle-nosignal-mystery-app ') alerts, want 1"
run $((NOW + 3900))
[ "$(nalert 'severity warn --id fly-idle-nosignal-mystery-app ')" = 1 ] && ok || bad "R5 the pass at +65 min sent a second alert"
machines mystery-app "$(mach $X1 stopped $((NOW - 90000)))"; run $((NOW + 4200))
[ "$(nalert 'resolve --id fly-idle-nosignal-mystery-app ')" = 1 ] && ok || bad "R5 the stopped machine sent no single resolve: $(cat "$FIX/alert-calls")"
[ -e "$H/state/fly-idle-reaper/nosignal/mystery-app" ] && bad "R5 the nosignal file survived" || ok
[ "$(stops)" = 0 ] && ok || bad "R5 a no-signal app was stopped on a later pass"

# ── R6. the queue cannot be read: unknown, and the alert after 3 passes ────
reset; touch "$FIX/queue-fail"; run
[ "$(stops)" = 0 ] && ok || bad "R6 a pool/builder machine was stopped with the queue unreadable: $(cat "$FIX/fly-calls")"
[ "$(row_state $P1)" = unknown ] && ok || bad "R6 the row is '$(row_state $P1)', want unknown"
grep -q 'unknown=2 ' "$H/logs/fly-idle-reaper.log" && ok || bad "R6 the log does not count 2 unknown: $(lastpass)"
run
[ "$(nalert 'id fly-idle-fail-pool-cromford ')" = 0 ] && ok || bad "R6 passes 1 and 2 alerted"
run
[ "$(nalert 'severity warn --id fly-idle-fail-pool-cromford ')" = 1 ] && ok || bad "R6 pass 3 sent $(nalert 'severity warn --id fly-idle-fail-pool-cromford ') fail alerts, want 1"
rm -f "$FIX/queue-fail"; run
[ "$(nalert 'resolve --id fly-idle-fail-pool-cromford ')" = 1 ] && ok || bad "R6 a readable pass did not resolve the fail alert"

# ── R8. the per-pass cap ───────────────────────────────────────────────────
reset; ms=()
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do ms+=("$(mach "1f1d000001$i" started $((NOW - 2000)))"); done
machines pool-cromford "${ms[@]}"; run
[ "$(stops)" = 10 ] && ok || bad "R8 12 over-threshold machines got $(stops) stops, want 10 (fly.idle_max_stops_per_pass)"
[ "$(jq '[.rows[] | select(.idle_state == "over")] | length' "$FIX/last-put.json")" = 2 ] && ok || bad "R8 want 2 rows over"

# ── R9. the stop fails: no row, a fail streak, the alert after 3 ───────────
reset; echo 1 > "$FIX/stop-rc"; run
grep -q '^POST /api/fly-idle/stops' "$FIX/jobs-calls" && bad "R9 a failed stop posted a row" || ok
[ "$(cat "$H/state/fly-idle-reaper/fail/pool-cromford__$P1" 2>/dev/null)" = 1 ] && ok || bad "R9 the fail count is not 1"
[ "$(row_state $P1)" = over ] && ok || bad "R9 the row is '$(row_state $P1)', want over"
grep -q 'stop_failed=1 ' "$H/logs/fly-idle-reaper.log" && ok || bad "R9 the log does not count stop_failed=1"
run; run
[ "$(nalert 'severity warn --id fly-idle-fail-pool-cromford ')" = 1 ] && ok || bad "R9 3 failed stops sent $(nalert 'severity warn --id fly-idle-fail-pool-cromford ') alerts, want 1"

# ── R10. no state/fly-pool: unknown, not idle ──────────────────────────────
reset; scratch_rm "$H/state/fly-pool" >/dev/null 2>&1; run
stopped $P1 pool-cromford && bad "R10 a pool machine was stopped with no state/fly-pool" || ok
[ "$(row_state $P1)" = unknown ] && ok || bad "R10 the row is '$(row_state $P1)', want unknown"

# ── R11. the lane-off flag ─────────────────────────────────────────────────
reset; : > "$H/flags/lane-off-fly-idle-reaper"; run
[ "$RC" = 0 ] && ok || bad "R11 the lane-off run exited $RC"
[ -s "$FIX/fly-calls" ] && bad "R11 the lane-off run called flyctl: $(cat "$FIX/fly-calls")" || ok

# ── R12. testhost: the idle verb decides ───────────────────────────────────
reset; echo 1000 > "$FIX/th-out"; run
stopped $T1 bh-testhost-example-org && ok || bad "R12a testhost idle 1000 was not stopped"
grep -q "^idle $T1 app=bh-testhost-example-org" "$FIX/th-calls" && ok || bad "R12a the idle verb was not asked for $T1: $(cat "$FIX/th-calls" 2>/dev/null)"
reset; echo 0 > "$FIX/th-out"; run
stopped $T1 bh-testhost-example-org && bad "R12b a busy testhost (0) was stopped" || ok
[ "$(row_state $T1)" = busy ] && ok || bad "R12b the row is '$(row_state $T1)', want busy"
reset; echo unknown > "$FIX/th-out"; echo 2 > "$FIX/th-rc"; run
stopped $T1 bh-testhost-example-org && bad "R12c an unknown testhost was stopped" || ok
[ "$(row_state $T1)" = unknown ] && ok || bad "R12c the row is '$(row_state $T1)', want unknown"

# ── R13. the lock ──────────────────────────────────────────────────────────
reset
exec 8>"$H/locks/fly-idle-reaper.lock"; flock -n 8
run
exec 8>&-
[ "$RC" = 0 ] && ok || bad "R13 a run with the lock held exited $RC"
[ -s "$FIX/fly-calls" ] && bad "R13 a run with the lock held called flyctl" || ok

# ── R14. settings ──────────────────────────────────────────────────────────
reset; : > "$FIX/settings-down/fly.idle_stop_after_s"; run
[ "$(stops)" = 0 ] && ok || bad "R14a an unreadable threshold row still stopped"
case "$(lastpass)" in *"nostop=1"*) ok ;; *) bad "R14a the log does not say nostop=1: $(lastpass)" ;; esac
[ "$(row_state $P1)" = over ] && ok || bad "R14a the row is '$(row_state $P1)', want over"
reset; echo 1200 > "$FIX/settings/fly.idle_stop_after_s.pool-cromford"; run
stopped $P1 pool-cromford && bad "R14b the per-app row 1200 did not hold back a 1000 s stop" || ok
reset; echo 500 > "$FIX/settings/fly.idle_stop_after_s"; machines pool-cromford "$(mach $P1 started $((NOW - 600)))"; run
stopped $P1 pool-cromford && ok || bad "R14c the row fly.idle_stop_after_s=500 did not stop a 600 s idle machine"
case "$(lastpass)" in *"threshold=500(row)"*) ok ;; *) bad "R14c the log does not say threshold=500(row): $(lastpass)" ;; esac

# ── R15. exempt ────────────────────────────────────────────────────────────
reset; apps bh-ci-runners-example-org; machines bh-ci-runners-example-org "$(mach 1f1d000000d1 started $((NOW - 36000)))"
run; run $((NOW + 7200))
[ "$(stops)" = 0 ] && ok || bad "R15 an exempt app was stopped"
[ -s "$FIX/alert-calls" ] && bad "R15 an exempt app alerted: $(cat "$FIX/alert-calls")" || ok
[ "$(row_state 1f1d000000d1)" = exempt ] && ok || bad "R15 the row is '$(row_state 1f1d000000d1)', want exempt"

# ── R17. the outbox survives a failed POST ─────────────────────────────────
reset; touch "$FIX/post-fail"; run
[ "$(ls "$H/state/fly-idle-reaper/outbox/" 2>/dev/null | wc -l)" = 1 ] && ok || bad "R17 a failed POST left no outbox file"
rm -f "$FIX/post-fail"; : > "$FIX/jobs-calls"; machines pool-cromford "$(mach $P1 stopped $((NOW - 1000)))"; run
[ "$(head -n 1 "$FIX/jobs-calls" | cut -d' ' -f1-2)" = "POST /api/fly-idle/stops" ] && ok || bad "R17 the next pass did not POST the outbox first: $(head -n 1 "$FIX/jobs-calls")"
[ -z "$(ls -A "$H/state/fly-idle-reaper/outbox" 2>/dev/null)" ] && ok || bad "R17 the outbox file was not removed after a good POST"

# ── R19. no token, no flyctl, the apps list fails ──────────────────────────
reset; : > "$H/env/fly.env"; run
[ "$RC" = 0 ] && ok || bad "R19a no token exited $RC, want 0"
[ -s "$FIX/fly-calls" ] && bad "R19a no token still called flyctl" || ok
[ "$(nalert 'id fly-idle-reaper-unconfigured ')" = 1 ] && ok || bad "R19a no token raised no fly-idle-reaper-unconfigured"
grep -q 'not configured' "$H/logs/fly-idle-reaper.log" && ok || bad "R19a the log does not say not configured"
reset
OUT=$(env PATH="/usr/bin:/bin" HOME="$T/home" HARNESS="$H" FIX="$FIX" FLY_IDLE_REAPER_NOW="$NOW" bash "$H/bin/fly-idle-reaper.sh" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R19b no flyctl exited $RC, want 1"
grep -q 'flyctl not found' "$FIX/alert-calls" 2>/dev/null && ok || bad "R19b the alert does not name 'flyctl not found'"
reset; touch "$FIX/apps-fail"; run
[ "$RC" = 1 ] && ok || bad "R19c a failed apps list exited $RC, want 1"
[ -e "$FIX/last-put.json" ] && bad "R19c a failed apps list still PUT a snapshot" || ok
run; run
[ "$(nalert 'severity warn --id fly-idle-reaper-list ')" = 1 ] && ok || bad "R19c 3 failed lists sent $(nalert 'severity warn --id fly-idle-reaper-list ') alerts, want 1"
# R18 here too: the stub's error line carries the token, and reset clears the log.
grep -q 'server error' "$H/logs/fly-idle-reaper.log" && ok || bad "R18 the apps-list error line is not in the log"
grep -q 'fm2_fixture' "$H/logs/fly-idle-reaper.log" "$FIX/alert-calls" 2>/dev/null \
  && bad "R18 the token from flyctl's error output reached the log or an alert" || ok
# A registry that does not validate stops nothing.
reset; cp "$H/catalog/fly-idle-signals.json" "$T/reg.bak"; echo '{"apps":[]}' > "$H/catalog/fly-idle-signals.json"; run
[ "$(stops)" = 0 ] && ok || bad "R19d a bad registry still stopped"
[ "$(nalert 'id fly-idle-reaper-registry ')" = 1 ] && ok || bad "R19d a bad registry raised no alert"
run $((NOW + 7200))
[ "$(nalert 'id fly-idle-nosignal-')" = 0 ] && ok || bad "R19d a bad registry turned every app into a nosignal alert: $(cat "$FIX/alert-calls")"
[ -z "$(ls -A "$H/state/fly-idle-reaper/nosignal" 2>/dev/null)" ] && ok || bad "R19d a bad registry started nosignal streaks"
[ "$(row_state $P1)" = unknown ] && ok || bad "R19d with a bad registry the row is '$(row_state $P1)', want unknown"
cp "$T/reg.bak" "$H/catalog/fly-idle-signals.json"

# ── R20. a machine id the worker would refuse stays out of the snapshot ────
reset; machines pool-cromford "$(mach $P1 started $((NOW - 1000)))" "$(mach m-notHex started $((NOW - 5000)))"; run
grep -q '^machine stop m-notHex' "$FIX/fly-calls" && bad "R20 a non-hex machine id was stopped" || ok
[ "$(jq -r '[.rows[].machine_id] | index("m-notHex")' "$FIX/last-put.json" 2>/dev/null)" = null ] && [ "$(row_state $P1)" = stopping ] \
  && ok || bad "R20 the snapshot carries the non-hex id, or lost the good row: $(cat "$FIX/last-put.json" 2>/dev/null)"
grep -q 'unknown=1 ' "$H/logs/fly-idle-reaper.log" && ok || bad "R20 the non-hex machine is not counted unknown: $(lastpass)"

# ── R16 / R18. never destroy; the token is nowhere ─────────────────────────
grep -qE 'destroy|apps (delete|destroy)' "$ALL" && bad "R16 a destroy reached flyctl: $(grep -E 'destroy|delete' "$ALL")" || ok
grep -rq 'fm2_fixture' "$H/logs" "$H/state" "$FIX/jobs-calls" "$FIX/alert-calls" 2>/dev/null \
  && bad "R18 the token value is in a log, a state file, a jobs request or an alert" || ok

echo "fly-idle-reaper: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
