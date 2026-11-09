#!/bin/bash
# tests/testhost-scale-zero.bh-9065-test.sh — the test hosts scale to zero
# (BH-9065 C3).
#
# THE DEFECT. bin/testhost-tick.sh managed ONE machine (`.[0].id` of the app)
# and read ONE shared idle clock (`testhost.last_used`) for it. The app has 4
# hosts. One gate run per window kept the shared row fresh, so every host read
# "in use … left started": 1,691 log lines and 0 stops since 2026-10-29.
#
# WHAT THIS PINS.
#   - the tick visits EVERY machine of the app, each on its OWN clock
#     (`testhost.last_used.<mid>`); the shared row is only the fallback when a
#     machine has no row of its own;
#   - the stop rule: per-machine idle >= window AND the probe says idle AND no
#     live route AND more machines started than TESTHOST_MIN_STARTED;
#   - `ensure` starts exactly one stopped machine when none is started, and
#     stamps the machine it starts or picks;
#   - `idle <mid>` reads that machine's row;
#   - a `stopped after` line only after a state read says stopped.
#
# Every case runs the REAL bin/testhost-tick.sh against a scratch $HARNESS with
# a fake flyctl first on PATH (every argv line recorded) and a fake jobs-client
# whose settings rows are files. A tripwire flyctl sits in $HOME/.fly/bin: if
# the lane ever reached past the fake, the tripwire file appears. 0 real Fly
# calls is asserted at the end.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/testhost-scale-zero.bh-9065-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$FIX/st" "$FIX/busy" "$T/fakebin" "$T/.fly/bin" \
  "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
scratch_install_closure bin/testhost-tick.sh "$H" >/dev/null || { echo "closure install of bin/testhost-tick.sh failed"; exit 1; }
cp "$(rendered_registry)" "$H/catalog/lanes.json"
NOW=$(date -u '+%s')
# Unique machine ids for this run (lowercase hex-ish: `idle <mid>` takes [a-z0-9]).
U=$(printf '%x' "$$")
A="a${U}01"; B="b${U}02"; C="c${U}03"; D="d${U}04"

cat > "$H/bin/jobs-client.sh" <<'STUB'
JOBS_BOX=fixture
flag_sync()  { return 1; }
setting_get() {
  [ -f "$FIX/d1-down" ] && return 1
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
setting_set() {
  [ -f "$FIX/d1-down" ] && return 1
  printf '%s' "$2" > "$FIX/settings/$1"
  printf '%s=%s\n' "$1" "$2" >> "$FIX/settings-writes"
  return 0
}
STUB
cat > "$H/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
echo '{"repo":"example-org/cromford","label":"bh-ci","total":4,"online":4,"idle":4,"busy":0,"offline":0}'
exit 0
STUB
chmod +x "$H/bin/ci-runners-status.sh"

# The fake flyctl. Machine ids are $FIX/ids (one per line, list order); each
# machine's state is $FIX/st/<mid>; the busy probe answers $FIX/busy/<mid>
# (a count, or `fail`). `machine stop` with $FIX/stop-noop answers rc 0 and
# changes nothing (Fly accepted the call, the machine did not stop).
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
mid_after() { local want="$1" prev="" a; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$*" in
  *"machine list"*|*"machines list"*)
    [ -f "$FIX/list-fails" ] && { echo "Oops" >&2; exit 1; }
    first=1; printf '['
    while read -r m; do
      [ -n "$m" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"id":"%s","name":"th-%s","state":"%s"}' "$m" "$m" "$(cat "$FIX/st/$m" 2>/dev/null || echo started)"
    done < "$FIX/ids"
    printf ']\n'; exit 0 ;;
  *"machine status"*)
    m=$(mid_after status "$@")
    printf 'Machine ID: %s\nState: %s\n\nVM\n CPU Kind │ performance\n vCPUs │ 16\n' "$m" "$(cat "$FIX/st/$m" 2>/dev/null || echo started)"
    exit 0 ;;
  *"ssh console"*)
    cat > /dev/null
    m=$(mid_after --machine "$@")
    case "$*" in *TESTHOST_DISK*) echo "TESTHOST_DISK 10% 10% none"; exit 0 ;; esac
    b=$(cat "$FIX/busy/$m" 2>/dev/null || echo 0)
    [ "$b" = fail ] && { echo "Error: ssh: no certificate" >&2; exit 1; }
    echo "Connecting to fdaa:..."; echo "TESTHOST_BUSY $b"; exit 0 ;;
  *"machine start"*)
    m=$(mid_after start "$@")
    [ -f "$FIX/start-fails" ] && { echo "Error: start failed" >&2; exit 1; }
    printf 'started\n' > "$FIX/st/$m"; exit 0 ;;
  *"machine stop"*)
    m=$(mid_after stop "$@")
    [ -f "$FIX/stop-noop" ] || printf 'stopped\n' > "$FIX/st/$m"; exit 0 ;;
esac
exit 0
STUB
cat > "$T/.fly/bin/flyctl" <<'STUB'
#!/bin/bash
: > "$FIX/REAL-FLY-REACHED"
exit 1
STUB
chmod +x "$T/fakebin/flyctl" "$T/.fly/bin/flyctl"
export FIX

run() { # run [verb...]; IDLE unset = the registry default
  OUT=$(env -u FLY_API_TOKEN -u FLY_ACCESS_TOKEN -u FLY_API_TOKEN_TESTHOST \
    PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    FLY_SYSTEM_DIRS= FLY_BIN_DIR="$T/no-fly" LANE_START_SPREAD_S=0 \
    TESTHOST_APP=bh-testhost-fixture ${IDLE:+TESTHOST_IDLE_STOP_MIN=$IDLE} \
    ${MINS:+TESTHOST_MIN_STARTED=$MINS} TESTHOST_DISK_ALERT_PCT=0 \
    bash "$TICK" "$@" 2>&1 </dev/null); RC=$?
}
reset() { # reset <mid...> — these machines, all started, no rows
  rm -f "$FIX/fly-calls" "$FIX/d1-down" "$FIX/list-fails" "$FIX/start-fails" "$FIX/stop-noop" \
        "$FIX/settings-writes" "$FIX"/settings/* "$FIX"/st/* "$FIX"/busy/* "$H/logs/testhost-tick.log"
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  : > "$FIX/ids"
  local m; for m in "$@"; do echo "$m" >> "$FIX/ids"; printf 'started\n' > "$FIX/st/$m"; done
  IDLE=10; MINS=""
}
st()      { printf '%s\n' "$2" > "$FIX/st/$1"; }
row()     { printf '%s' "$((NOW - $2))" > "$FIX/settings/testhost.last_used.$1"; }  # row <mid> <age s>
shared()  { printf '%s' "$((NOW - $1))" > "$FIX/settings/testhost.last_used"; }
calls()   { cat "$FIX/fly-calls" 2>/dev/null; }
stops_of(){ grep -c "^machine stop $1 " "$FIX/fly-calls" 2>/dev/null; }
n_calls() { local n; n=$(grep -c "$1" "$FIX/fly-calls" 2>/dev/null); echo "${n:-0}"; }
state_of(){ cat "$FIX/st/$1" 2>/dev/null; }
rowval()  { cat "$FIX/settings/testhost.last_used.$1" 2>/dev/null; }

# ── S1. the window boundary, per machine ────────────────────────────────────
reset "$A"; row "$A" 540            # 9 minutes, window 10
run
[ "$RC" = 0 ] && ok || bad "S1a tick exited $RC: $OUT"
[ "$(state_of "$A")" = started ] && [ "$(n_calls 'machine stop')" = 0 ] && ok \
  || bad "S1a a host idle 9 min (window 10) was stopped: $(calls)"

reset "$A"; row "$A" 600            # exactly 10 minutes
run
[ "$(state_of "$A")" = stopped ] && ok || bad "S1b a host idle 10 min (window 10) was not stopped: $(calls) / $OUT"
grep -q "stopped after" "$H/logs/testhost-tick.log" 2>/dev/null && ok \
  || bad "S1c no 'stopped after' line for a machine the state read shows stopped: $(cat "$H/logs/testhost-tick.log" 2>/dev/null)"

# The window default is the registry's (10), not a code constant.
reset "$A"; IDLE=""; row "$A" 660
run
[ "$(state_of "$A")" = stopped ] && ok \
  || bad "S1d with no TESTHOST_IDLE_STOP_MIN override, a host idle 11 min was not stopped (registry default must be 10): $(calls)"

# ── S2. the probe and the route still hold the stop ─────────────────────────
reset "$A"; row "$A" 660; echo 3 > "$FIX/busy/$A"
run
[ "$(state_of "$A")" = started ] && ok || bad "S2a a host idle 11 min with the probe busy was stopped"
grep -q -- "--machine $A" "$FIX/fly-calls" && ok || bad "S2b the busy probe did not go to machine $A: $(calls)"
LU=$(rowval "$A")
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "S2c the busy refresh did not stamp testhost.last_used.$A ('$LU')"

reset "$A"; row "$A" 660; echo fail > "$FIX/busy/$A"
run
[ "$(state_of "$A")" = started ] && ok || bad "S2d a host whose probe failed (unknown) was stopped"

reset "$A"; row "$A" 660; printf '%s' "$((NOW + 3600))" > "$FIX/settings/testhost.route_until"
run
[ "$(state_of "$A")" = started ] && ok || bad "S2e a host with a live route was stopped"

# ── S3. the shared row is the fallback only ─────────────────────────────────
reset "$A"; shared 3600             # no per-machine row, shared row 1 h old
run
[ "$(state_of "$A")" = stopped ] && ok \
  || bad "S3a a host with no row of its own and an old shared row was not stopped (fallback): $(calls) / $OUT"

reset "$A"                          # no rows at all
run
[ "$(n_calls 'machine stop')" = 0 ] && ok || bad "S3b a tick with no rows stopped a machine"
LU=$(rowval "$A")
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "S3c a tick with no rows did not start the clock in testhost.last_used.$A ('$LU')"

# A fresh row of machine A does not protect machine B.
reset "$A" "$B"; row "$A" 60; row "$B" 3600
run
[ "$(state_of "$A")" = started ] && ok || bad "S3d machine A (used 1 min ago) was stopped"
[ "$(state_of "$B")" = stopped ] && ok \
  || bad "S3e machine B (own row 1 h old) was kept because machine A's row is fresh: $(calls) / $OUT"

# A fresh SHARED row does not protect a machine whose own row is old.
reset "$A" "$B"; shared 60; row "$A" 3600; row "$B" 3600
run
[ "$(state_of "$A")" = stopped ] && [ "$(state_of "$B")" = stopped ] && ok \
  || bad "S3f a fresh shared row kept machines whose own rows are 1 h old: A=$(state_of "$A") B=$(state_of "$B")"

# ── S4. TESTHOST_MIN_STARTED ────────────────────────────────────────────────
reset "$A"; MINS=1; row "$A" 3600
run
[ "$(state_of "$A")" = started ] && ok || bad "S4a the last started host was stopped with TESTHOST_MIN_STARTED=1"

reset "$A" "$B"; MINS=1; row "$A" 3600; row "$B" 3600
run
[ "$(n_calls 'machine stop')" = 1 ] && ok \
  || bad "S4b two idle hosts with TESTHOST_MIN_STARTED=1: want exactly 1 stop, got $(n_calls 'machine stop'): $(calls)"

# ── S5. four machines, one in use: the other three stop ─────────────────────
reset "$A" "$B" "$C" "$D"; row "$A" 120; row "$B" 3600; row "$C" 3600; row "$D" 3600
run
[ "$(state_of "$A")" = started ] && ok || bad "S5a the host used 2 min ago was stopped"
[ "$(state_of "$B")" = stopped ] && [ "$(state_of "$C")" = stopped ] && [ "$(state_of "$D")" = stopped ] && ok \
  || bad "S5b the 3 idle hosts were not all stopped: B=$(state_of "$B") C=$(state_of "$C") D=$(state_of "$D") / $(calls)"
[ "$(n_calls 'machine stop')" = 3 ] && ok || bad "S5c want 3 stop calls, got $(n_calls 'machine stop')"

# ── S6. a stop Fly accepted but the machine did not do: no "stopped after" ──
reset "$A"; row "$A" 3600; : > "$FIX/stop-noop"
run
grep -q "stopped after" "$H/logs/testhost-tick.log" 2>/dev/null \
  && bad "S6 'stopped after' was logged though the state read still says started: $(cat "$H/logs/testhost-tick.log")" || ok

# ── S7. ensure: one start when nothing is started ──────────────────────────
reset "$A" "$B" "$C" "$D"; st "$A" stopped; st "$B" stopped; st "$C" stopped; st "$D" stopped
run ensure --route-until "$((NOW + 3600))"
[ "$RC" = 0 ] && ok || bad "S7a ensure exited $RC: $OUT"
[ "$(n_calls 'machine start')" = 1 ] && ok || bad "S7b want exactly 1 machine start, got $(n_calls 'machine start'): $(calls)"
case "$OUT" in *"ensure-result: started-now"*) ok ;; *) bad "S7c no 'ensure-result: started-now': $OUT" ;; esac
SM=$(sed -n 's/^machine start \([^ ]*\) .*/\1/p' "$FIX/fly-calls" | head -1)
LU=$(rowval "${SM:-none}")
[ -n "$SM" ] && [ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "S7d ensure did not stamp the machine it started ('$SM', row '$LU')"
[ "$(n_calls 'machine stop')" = 0 ] && ok || bad "S7e ensure stopped a machine"

reset "$A" "$B"; st "$A" stopped; st "$B" stopped; : > "$FIX/start-fails"
run ensure --route-until "$((NOW + 3600))"
[ "$RC" = 1 ] && ok || bad "S7f a failed start exited $RC, want 1"
case "$OUT" in *"ensure-result: start-failed"*) ok ;; *) bad "S7g no 'ensure-result: start-failed': $OUT" ;; esac

# One machine started: ensure picks it, starts nothing, stamps only it.
reset "$A" "$B" "$C"; st "$A" stopped; st "$C" stopped
run ensure --route-until "$((NOW + 3600))"
[ "$(n_calls 'machine start')" = 0 ] && ok || bad "S7h ensure started a machine though $B is started: $(calls)"
case "$OUT" in *"ensure-result: was-started"*) ok ;; *) bad "S7i no 'ensure-result: was-started': $OUT" ;; esac
LU=$(rowval "$B")
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok || bad "S7j ensure did not stamp the started machine $B ('$LU')"
[ -z "$(rowval "$A")$(rowval "$C")" ] && ok || bad "S7k ensure stamped a machine it did not pick"

# ── S8. idle <mid> reads that machine's row ────────────────────────────────
reset "$A" "$B"; row "$A" 30; row "$B" 1000
run idle "$B"
[ "$RC" = 0 ] && [ "$OUT" -ge 1000 ] 2>/dev/null && [ "$OUT" -lt 1100 ] 2>/dev/null && ok \
  || bad "S8a idle $B (own row 1000 s) printed '$OUT' rc $RC — it read another machine's clock"
reset "$A"; shared 500
run idle "$A"
[ "$RC" = 0 ] && [ "$OUT" -ge 500 ] 2>/dev/null && [ "$OUT" -lt 600 ] 2>/dev/null && ok \
  || bad "S8b idle with no own row and a shared row 500 s printed '$OUT' rc $RC (want the fallback)"
reset "$A"
run idle "$A"
[ "$RC" = 2 ] && [ "$OUT" = unknown ] && ok || bad "S8c idle with no rows printed '$OUT' rc $RC, want unknown rc 2"
[ ! -s "$FIX/settings-writes" ] && ok || bad "S8d idle wrote a settings row: $(cat "$FIX/settings-writes")"
reset "$A"; MINS=1; row "$A" 3600
run idle "$A"
[ "$OUT" = 0 ] && ok || bad "S8e idle on the last started host with TESTHOST_MIN_STARTED=1 printed '$OUT' — the reaper would stop what the tick keeps"

# ── S9. no worker, no Fly call ─────────────────────────────────────────────
reset "$A" "$B"; row "$A" 3600; : > "$FIX/d1-down"
run
[ -z "$(calls)" ] && ok || bad "S9 an unreachable worker still cost a Fly call: $(calls)"

# ── S10. 0 real Fly calls in this whole suite ──────────────────────────────
[ ! -e "$FIX/REAL-FLY-REACHED" ] && ok || bad "S10 a flyctl other than the fake was called"

echo "testhost-scale-zero BH-9065: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
