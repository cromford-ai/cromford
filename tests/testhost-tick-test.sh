#!/bin/bash
# tests/testhost-tick-test.sh — bin/testhost-tick.sh, the shared test host's
# on-demand start and idle stop (BH-1205).
#
# WHAT THIS PINS AND WHY. This lane is the only thing in the fleet that STOPS a
# machine other agents are using, and the only thing that starts one nobody
# asked for. Both directions are expensive when they are wrong, in opposite
# ways: a wrong stop kills a drain mid-suite, a wrong start bills a
# performance-16x machine all night.
#
#   - the lane's off switch must stop EVERY Fly call, not just the stop;
#   - a worker that does not answer means the tick does NOTHING. `last_used`
#     lives in D1, and a tick that cannot read it cannot know whether the host
#     is idle — stopping on no evidence is exactly the wrong default;
#   - the idle window is a knob, read through the registry, and the boundary is
#     measured rather than asserted about;
#   - `ensure` starts a stopped machine and never stops anything.
#
# Every section runs the REAL bin/testhost-tick.sh against a scratch $HARNESS
# with a stubbed flyctl (every argv line recorded) and a stubbed jobs-client
# whose settings live in files. Assertions are on the recorded calls and the
# settings the lane wrote, never on the script's source text.
#
# Run from anywhere: tests/testhost-tick-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$T/fakebin" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
# ONE clock read for the whole file; every age below is derived from it.
NOW=$(date -u '+%s')

# The jobs-client stub. setting_get/setting_set are files under $FIX/settings;
# flag_sync answers rc 1 (outage) so bin/lib/lane-gate.sh falls back to the flag
# FILE, which is what the lane-off sections below drive.
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

# The flyctl stub: every call recorded, the state and the machine list are
# fixture files.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$*" in
  *"machines list"*|*"machine list"*)
    [ -f "$FIX/list-fails" ] && { echo "Oops" >&2; exit 1; }
    cat "$FIX/machines.json"; exit 0 ;;
  *"machine status"*|*"machines status"*)
    [ -f "$FIX/status-fails" ] && { echo "Error: machine not found" >&2; exit 1; }
    printf 'Machine ID: 873eddb0433018\nState: %s\n\nVM\n ID  | 873eddb0433018\n CPU Kind │ %s\n vCPUs │ %s\n' \
      "$(cat "$FIX/state" 2>/dev/null || echo started)" \
      "$(cat "$FIX/cpukind" 2>/dev/null || echo performance)" \
      "$(cat "$FIX/vcpus" 2>/dev/null || echo 16)"
    exit 0 ;;
  *"ssh console"*)
    [ -f "$FIX/probe-fails" ] && { echo "Error: ssh: no certificate" >&2; exit 1; }
    [ -f "$FIX/probe-garbage" ] && { echo "Connecting to fdaa:..."; exit 0; }
    echo "Connecting to fdaa:..."
    echo "TESTHOST_BUSY $(cat "$FIX/busy" 2>/dev/null || echo 0)"; exit 0 ;;
  *"machine start"*) printf 'started\n' > "$FIX/state"; exit 0 ;;
  *"machine stop"*)  printf 'stopped\n' > "$FIX/state"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/*
# BH-1210: every tick now also reads the bh-ci runner pool. Without this stub
# the lane would fall through to the checkout's real bin/ci-runners-status.sh
# and shell out to `gh` on each of this suite's ~25 ticks. rc 0 is a healthy
# pool, so the pool condition does nothing and no assertion below changes.
# tests/ci-runners-alert.bh-1210-test.sh is where that condition is pinned.
cat > "$H/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
echo '{"repo":"example-org/cromford","label":"bh-ci","total":74,"online":74,"idle":70,"busy":4,"offline":0}'
exit 0
STUB
chmod +x "$H/bin/ci-runners-status.sh"
printf '[{"id":"873eddb0433018","name":"testhost-1","state":"started"}]\n' > "$FIX/machines.json"
export FIX

run() { # run [verb...]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_IDLE_STOP_MIN="${IDLE:-30}" \
    TESTHOST_SIZE="${SIZE:-performance-16x}" \
    bash "$TICK" "$@" 2>&1); RC=$?
}
reset() {
  rm -f "$FIX/fly-calls" "$FIX/d1-down" "$FIX/list-fails" "$FIX/status-fails" \
        "$FIX/probe-fails" "$FIX/probe-garbage" "$FIX/busy" \
        "$FIX/settings-writes" "$FIX"/settings/* "$H/flags/lane-off-testhost-tick" \
        "$H/logs/testhost-tick.log"
  # scratch_rm, not rm -rf: the gate's flag cache has to go between cases (a
  # stale one answers for the next case), and checks/tests-scratch-only cannot
  # prove "$H" is under "$T" by reading this file — nor should it have to.
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  printf 'started\n' > "$FIX/state"; printf 'performance\n' > "$FIX/cpukind"; printf '16\n' > "$FIX/vcpus"
  printf '0\n' > "$FIX/busy"       # nothing running on the host unless a case says so
  IDLE=30; SIZE=performance-16x
}
calls() { cat "$FIX/fly-calls" 2>/dev/null; }
stamp() { printf '%s' "$1" > "$FIX/settings/testhost.last_used"; }

# ── 1. the lane's off switch stops every Fly call ───────────────────────────
reset; : > "$H/flags/lane-off-testhost-tick"; stamp "$((NOW - 7200))"
run
[ "$RC" = 0 ] && ok || bad "1a a gated tick exited $RC (a skip is not a failure — cron mails on nonzero)"
[ -z "$(calls)" ] && ok || bad "1b a gated tick still called Fly: $(calls)"

reset; : > "$H/flags/lane-off-testhost-tick"
run ensure
[ "$RC" = 0 ] && ok || bad "1c a gated ensure exited $RC"
[ -z "$(calls)" ] && ok || bad "1d a gated ensure still called Fly: $(calls)"

# ── 2. a worker that does not answer means no machine action ────────────────
reset; : > "$FIX/d1-down"; stamp "$((NOW - 7200))"
run
[ "$RC" = 0 ] && ok || bad "2a an unreachable worker exited $RC (want 0 — the fleet keeps running)"
[ -z "$(calls)" ] && ok || bad "2b an unreachable worker still cost a Fly call: $(calls)"
# The WORDS, not just "it printed something". With a looser assertion, deleting
# this branch entirely left the suite green: the empty answer fell through to
# the no-row branch, which also does nothing, and the test could not tell the
# two apart.
case "$OUT" in *"did not answer for testhost.last_used"*) ok ;; *) bad "2c the tick did not name the outage it hit: $OUT" ;; esac
case "$OUT" in *"starting the clock"*) bad "2d an outage was reported as a missing row — the lane would stamp over a row it could not read" ;; *) ok ;; esac

# ── 2b. no row at all: start the clock, touch no machine ───────────────────
# The old lane did nothing for ever when the row was missing, so the machine it
# exists to stop was never stopped and the cost promise quietly did not happen.
reset
run
[ "$RC" = 0 ] && ok || bad "2e a first tick with no row exited $RC"
case "$(calls)" in *"machine stop"*|*"machine start"*) bad "2f the first tick moved the machine" ;; *) ok ;; esac
# BH-9065: the clock is per machine, so the tick starts the machine's OWN row
# (testhost.last_used.<mid>), not the shared one.
LU=$(cat "$FIX/settings/testhost.last_used.873eddb0433018" 2>/dev/null)
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "2g a missing row left the clock unstarted ('$LU' in testhost.last_used.873eddb0433018) — the host would never be stopped"

# ── 3. idle past the window: stop, and record what the machine now is ───────
reset; stamp "$((NOW - 3600))"   # an hour idle, window 30 minutes
run
[ "$RC" = 0 ] && ok || bad "3a an idle-stop tick exited $RC"
case "$(calls)" in *"machine stop"*) ok ;; *) bad "3b an hour-idle host was not stopped: $(calls)" ;; esac
[ "$(cat "$FIX/settings/testhost.machine_state" 2>/dev/null)" = stopped ] && ok \
  || bad "3c testhost.machine_state was not written as stopped: $(cat "$FIX/settings/testhost.machine_state" 2>/dev/null)"

# ── 4. inside the window: nothing is stopped ────────────────────────────────
reset; stamp "$((NOW - 60))"
run
case "$(calls)" in *"machine stop"*) bad "4a a host used one minute ago was stopped" ;; *) ok ;; esac

# The window is a KNOB, not a constant: at IDLE=1 the same one-minute-old stamp
# is past the window.
reset; IDLE=1; stamp "$((NOW - 300))"
run
case "$(calls)" in *"machine stop"*) ok ;; *) bad "4b TESTHOST_IDLE_STOP_MIN=1 did not stop a five-minute-idle host: $(calls)" ;; esac

# ── 5. a machine already stopped is left alone ──────────────────────────────
reset; printf 'stopped\n' > "$FIX/state"; stamp "$((NOW - 7200))"
run
case "$(calls)" in *"machine stop"*) bad "5 a stopped machine was stopped again" ;; *) ok ;; esac

# ── 6. ensure: start on demand, stamp the use, never stop ───────────────────
reset; printf 'stopped\n' > "$FIX/state"
run ensure
[ "$RC" = 0 ] && ok || bad "6a ensure exited $RC on a stopped machine: $OUT"
case "$(calls)" in *"machine start"*) ok ;; *) bad "6b ensure did not start the stopped machine: $(calls)" ;; esac
case "$(calls)" in *"machine stop"*) bad "6c ensure stopped a machine" ;; *) ok ;; esac
LU=$(cat "$FIX/settings/testhost.last_used" 2>/dev/null)
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok || bad "6d ensure did not stamp testhost.last_used (got '$LU')"

reset   # already started: nothing to start
run ensure
case "$(calls)" in *"machine start"*) bad "6e ensure started a machine that was already started" ;; *) ok ;; esac
[ -n "$(cat "$FIX/settings/testhost.last_used" 2>/dev/null)" ] && ok \
  || bad "6f ensure on a running machine did not stamp the use — the next tick would stop it mid-run"

# An unreachable worker must NOT stop a human's run from starting: the start is
# what was asked for, the stamp is the bookkeeping.
reset; printf 'stopped\n' > "$FIX/state"; : > "$FIX/d1-down"
run ensure
case "$(calls)" in *"machine start"*) ok ;; *) bad "6g ensure refused to wake the host because D1 was down: $(calls) / $OUT" ;; esac
case "$OUT" in *testhost-tick:*) ok ;; *) bad "6h ensure was silent about not recording the use: $OUT" ;; esac

# ── 7. the size knob is really read ─────────────────────────────────────────
# performance/16 vCPUs is performance-16x. A lane that says 16x over a machine
# that is not says so, in the log, rather than quietly billing the difference.
reset; SIZE=performance-8x; stamp "$((NOW - 60))"
run
grep -qi "size" "$H/logs/testhost-tick.log" 2>/dev/null && ok \
  || bad "7a a size mismatch (lane says performance-8x, machine is performance-16x) was not logged: $(cat "$H/logs/testhost-tick.log" 2>/dev/null)"
reset; stamp "$((NOW - 60))"
run
grep -qi "drift" "$H/logs/testhost-tick.log" 2>/dev/null \
  && bad "7b a matching size was reported as drift: $(cat "$H/logs/testhost-tick.log" 2>/dev/null)" || ok

# ── 10. the machine's own answer outranks the row ──────────────────────────
# THE BLOCKING FINDING OF THE REVIEW. `last_used` is written by a gate run that
# has a worker credential; a Mac does not, so a full Mac drain can leave the row
# hours old while sixteen suites a minute run on the host. Stopping on the row
# alone kills that drain, and does it again every window.
reset; stamp "$((NOW - 7200))"; printf '35\n' > "$FIX/busy"
run
case "$(calls)" in *"machine stop"*) bad "10a a host with 35 live runs was stopped because a row said idle" ;; *) ok ;; esac
case "$(calls)" in *"ssh console"*) ok ;; *) bad "10b the tick never asked the machine what was running: $(calls)" ;; esac
case "$OUT" in *BUSY*) ok ;; *) bad "10c the tick did not say why it left the host alone: $OUT" ;; esac
# and it repairs the bookkeeping for the runner that could not write it, on
# the probed machine's own clock (BH-9065: testhost.last_used.<mid>)
LU=$(cat "$FIX/settings/testhost.last_used.873eddb0433018" 2>/dev/null)
[ -n "$LU" ] && [ "$LU" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "10d a busy host did not refresh testhost.last_used.873eddb0433018 ('$LU') — the same stale row would try again in five minutes"

# A probe that cannot answer is busy, never idle.
reset; stamp "$((NOW - 7200))"; : > "$FIX/probe-fails"
run
case "$(calls)" in *"machine stop"*) bad "11a a host we could not ask was stopped anyway" ;; *) ok ;; esac
case "$OUT" in *"NOT stopping"*) ok ;; *) bad "11b a failed probe did not say it was refusing to stop: $OUT" ;; esac

# An answer that is not a number is not "zero things running".
reset; stamp "$((NOW - 7200))"; : > "$FIX/probe-garbage"
run
case "$(calls)" in *"machine stop"*) bad "11c an unparseable probe answer was read as idle" ;; *) ok ;; esac

# Both witnesses agree: row idle AND the host reports nothing running.
reset; stamp "$((NOW - 7200))"; printf '0\n' > "$FIX/busy"
run
case "$(calls)" in *"machine stop"*) ok ;; *) bad "11d a provably idle host was not stopped: $(calls) / $OUT" ;; esac

# ── 8. Fly not answering is not "stopped" ───────────────────────────────────
# A status call that fails must never be read as a state, and must never be the
# reason a machine is started or stopped.
reset; : > "$FIX/status-fails"; stamp "$((NOW - 7200))"
run
[ "$RC" = 0 ] && ok || bad "8a an unreadable machine state exited $RC (want 0)"
case "$(calls)" in *"machine stop"*) bad "8b a machine whose state could not be read was stopped anyway" ;; *) ok ;; esac

# ── 9. state is a read, and prints one word ────────────────────────────────
reset
run state
[ "$RC" = 0 ] && ok || bad "9a state exited $RC"
case "$OUT" in *started*) ok ;; *) bad "9b state did not print the machine state: $OUT" ;; esac
case "$(calls)" in *"machine start"*|*"machine stop"*) bad "9c a read changed the machine" ;; *) ok ;; esac

# ── 12. busy is a read ─────────────────────────────────────────────────────
# The verb an operator runs before touching the host, and the way the probe
# that decides the stop is exercised against the live machine without stopping
# anything.
reset; printf '7\n' > "$FIX/busy"
run busy
[ "$RC" = 0 ] && ok || bad "12a busy exited $RC"
case "$OUT" in *"busy 7"*) ok ;; *) bad "12b busy did not print the count: $OUT" ;; esac
case "$(calls)" in *"machine start"*|*"machine stop"*) bad "12c a read changed the machine" ;; *) ok ;; esac
reset; printf '0\n' > "$FIX/busy"
run busy
case "$OUT" in *idle*) ok ;; *) bad "12d an empty host did not read as idle: $OUT" ;; esac
reset; : > "$FIX/probe-fails"
run busy
case "$OUT" in *unknown*) ok ;; *) bad "12e a failed probe did not read as unknown: $OUT" ;; esac

echo "testhost-tick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
