#!/bin/bash
# tests/ci-runners-alert.bh-1210-test.sh — the bh-ci runner pool condition the
# `testhost-tick` lane carries (BH-1210).
#
# WHAT THIS PINS AND WHY. Harness CI has no GitHub-hosted fallback: when the Fly
# `bh-ci` pool is empty the jobs QUEUE instead of failing, so no PR turns red,
# nothing pages, and the drain simply stops merging. The lane's job is to turn
# that silence into exactly one alert — and to be wrong in neither direction:
#
#   - a pool that answers "nothing online" for ten continuous minutes alerts
#     ONCE, however long the outage then lasts;
#   - a single tick catching a machine restart alerts NEVER;
#   - a read that FAILED (rc 2, a missing script, a 403 token) is its own
#     quieter condition and must never render as "no runners". That is the
#     failure that hides the failure: a broken token would otherwise page the
#     fleet about a pool that is perfectly healthy;
#   - the way back up sends a resolve, or the first green tick after an outage
#     leaves the condition open for ever.
#
# Every case runs the REAL bin/testhost-tick.sh with the real `tick` verb
# against a scratch $HARNESS. The script is COPIED into that scratch tree so
# `$(dirname "$0")` resolves there too: case 11 removes the status script to
# prove a missing read is "unreadable", and a fallback reaching the checkout's
# own bin/ would shell out to `gh` and hit the network. Assertions are on the
# recorded argv of the stubbed emitters and on the settings rows the lane wrote,
# never on the lane's source text.
#
# Run from anywhere: tests/ci-runners-alert.bh-1210-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED and not committed.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$T/fakebin" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
scratch_install_closure bin/testhost-tick.sh "$H" >/dev/null || { echo "FAIL: could not install the tick's closure"; exit 1; }
# ONE clock read for the whole file; every age below is derived from it.
NOW=$(date -u '+%s')

POOL_OK='{"repo":"example-org/cromford","label":"bh-ci","total":74,"online":74,"idle":70,"busy":4,"offline":0}'
POOL_EMPTY='{"repo":"example-org/cromford","label":"bh-ci","total":74,"online":0,"idle":0,"busy":0,"offline":74}'

# The jobs-client stub: setting_get/setting_set are files under $FIX/settings,
# and $FIX/d1-down is the worker outage. flag_sync answers rc 1 so
# bin/lib/lane-gate.sh falls back to the flag FILE, which section 12 drives.
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

# The pool read: argv recorded, rc and body from fixture files.
cat > "$H/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ci-calls"
[ -f "$FIX/ci-body" ] && cat "$FIX/ci-body"
exit "$(cat "$FIX/ci-rc" 2>/dev/null || echo 0)"
STUB

# The emitter: argv recorded, one line per call, $FIX/alert-fails makes the
# send fail so the "send first, stamp second" ordering can be measured.
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
[ -f "$FIX/alert-fails" ] && exit 1
exit 0
STUB

# flyctl: the Fly half of the lane does nothing interesting here, but it must
# still answer, and $FIX/status-fails is section 14's unreadable machine.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$*" in
  *"machine list"*|*"machines list"*) cat "$FIX/machines.json"; exit 0 ;;
  *"machine status"*|*"machines status"*)
    [ -f "$FIX/status-fails" ] && { echo "Error: machine not found" >&2; exit 1; }
    printf 'Machine ID: 873eddb0433018\nState: started\n\nVM\n CPU Kind │ performance\n vCPUs │ 16\n'
    exit 0 ;;
  *"ssh console"*) echo "TESTHOST_BUSY 0"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/* "$H/bin/ci-runners-status.sh" "$H/bin/lane-alert.sh"
printf '[{"id":"873eddb0433018","name":"testhost-1","state":"started"}]\n' > "$FIX/machines.json"
export FIX

run() { # run [verb...]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    TESTHOST_APP=bh-testhost-fixture \
    CI_RUNNERS_ALERT_HOLD_MIN="${HOLD:-10}" \
    bash "$H/bin/testhost-tick.sh" "$@" 2>&1); RC=$?
}
reset() {
  rm -f "$FIX/ci-calls" "$FIX/alert-calls" "$FIX/fly-calls" "$FIX/d1-down" \
        "$FIX/alert-fails" "$FIX/status-fails" "$FIX/settings-writes" \
        "$FIX"/settings/* "$H/flags/lane-off-testhost-tick" \
        "$H/logs/testhost-tick.log"
  # scratch_rm, not rm -rf: the gate's flag cache has to go between cases (a
  # stale one answers for the next case).
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  [ -x "$H/bin/ci-runners-status.sh" ] || { cp "$FIX/ci-stub" "$H/bin/ci-runners-status.sh"; chmod +x "$H/bin/ci-runners-status.sh"; }
  pool 0 "$POOL_OK"
  # The Fly half is quiet in every case here: a use one minute old is inside the
  # idle window, so the tick reads the state and stops.
  printf '%s' "$((NOW - 60))" > "$FIX/settings/testhost.last_used"
  rm -f "$FIX/settings-writes"
  HOLD=10
}
cp "$H/bin/ci-runners-status.sh" "$FIX/ci-stub"

pool()    { printf '%s\n' "$1" > "$FIX/ci-rc"; printf '%s\n' "$2" > "$FIX/ci-body"; }
row()     { printf '%s' "$2" > "$FIX/settings/$1"; }
rowval()  { cat "$FIX/settings/$1" 2>/dev/null; }
alerts()  { cat "$FIX/alert-calls" 2>/dev/null; }
nalerts() { if [ -f "$FIX/alert-calls" ]; then wc -l < "$FIX/alert-calls" | tr -d ' '; else echo 0; fi; }
ncalls()  { if [ -f "$FIX/ci-calls" ]; then wc -l < "$FIX/ci-calls" | tr -d ' '; else echo 0; fi; }

# ── 1. a healthy pool is silent ────────────────────────────────────────────
reset
run
[ "$RC" = 0 ] && ok || bad "1a a healthy-pool tick exited $RC"
[ "$(nalerts)" = 0 ] && ok || bad "1b a healthy pool alerted: $(alerts)"
[ -z "$(grep 'ci_runners\.' "$FIX/settings-writes" 2>/dev/null)" ] && ok \
  || bad "1c a healthy pool wrote streak rows it did not need: $(grep 'ci_runners\.' "$FIX/settings-writes" 2>/dev/null)"

# ── 13. the read is the real one, with --json ──────────────────────────────
case "$(cat "$FIX/ci-calls" 2>/dev/null)" in *--json*) ok ;; *) bad "13 the tick did not ask ci-runners-status.sh for --json: $(cat "$FIX/ci-calls" 2>/dev/null)" ;; esac

# ── 2. the first empty read starts the clock and says nothing ──────────────
reset; pool 1 "$POOL_EMPTY"
run
[ "$(nalerts)" = 0 ] && ok || bad "2a one empty read alerted — a machine restarting is not an outage: $(alerts)"
S=$(rowval ci_runners.empty_since)
[ -n "$S" ] && [ "$S" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "2b the first empty read did not start the clock ('$S') — the hold could never elapse"

# ── 5. five minutes of empty is still inside the hold ──────────────────────
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 300))"
run
[ "$(nalerts)" = 0 ] && ok || bad "5a an empty pool alerted after 5 minutes of a 10-minute hold: $(alerts)"
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 300))" ] && ok \
  || bad "5b the streak row moved while the hold was still running: $(rowval ci_runners.empty_since)"

# ── 3. eleven minutes of empty is the alert ────────────────────────────────
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
run
[ "$(nalerts)" = 1 ] && ok || bad "3a want exactly one alert past the hold, got $(nalerts): $(alerts)"
case "$(alerts)" in *"--severity critical"*) ok ;; *) bad "3b the pool alert was not critical: $(alerts)" ;; esac
case "$(alerts)" in *"--id ci-runners-empty"*) ok ;; *) bad "3c the pool alert carried no stable condition id: $(alerts)" ;; esac
case "$(alerts)" in *testhost-tick*) ok ;; *) bad "3d the alert did not name the lane: $(alerts)" ;; esac
case "$(alerts)" in *"0 of 74"*) ok ;; *) bad "3e the alert text carries no counts from the body that was read: $(alerts)" ;; esac
case "$(alerts)" in *example-org/cromford*) ok ;; *) bad "3f the alert text does not name the repo: $(alerts)" ;; esac
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 660)):fired" ] && ok \
  || bad "3g the streak row was not stamped as fired: $(rowval ci_runners.empty_since)"

# ── 4. one alert per outage, however long it lasts ─────────────────────────
# Deliberately NOT reset: the four ticks below continue the outage above.
run; run; run; run
[ "$(nalerts)" = 1 ] && ok || bad "4 four more ticks of the same outage sent $(nalerts) alerts (want 1): $(alerts)"

# ── 6. the way back up ─────────────────────────────────────────────────────
reset; pool 0 "$POOL_OK"; row ci_runners.empty_since "$((NOW - 660)):fired"
run
[ "$(nalerts)" = 1 ] && ok || bad "6a want exactly one send on recovery, got $(nalerts): $(alerts)"
case "$(alerts)" in *--resolve*) ok ;; *) bad "6b recovery did not resolve the condition: $(alerts)" ;; esac
case "$(alerts)" in *"--id ci-runners-empty"*) ok ;; *) bad "6c the resolve named no id, so nothing closes: $(alerts)" ;; esac
[ "$(rowval ci_runners.empty_since)" = 0 ] && ok \
  || bad "6d the streak row was not cleared after the resolve: $(rowval ci_runners.empty_since)"
# and the next green tick is silent again
run
[ "$(nalerts)" = 1 ] && ok || bad "6e a second green tick sent another resolve: $(alerts)"

# A single empty tick followed by a green one is the ticket's machine restart:
# the clock is thrown away and nobody is told anything.
reset; pool 1 "$POOL_EMPTY"
run
pool 0 "$POOL_OK"
run
[ "$(nalerts)" = 0 ] && ok || bad "6f a restart (one empty read, then online) alerted: $(alerts)"
[ "$(rowval ci_runners.empty_since)" = 0 ] && ok \
  || bad "6g a recovered pool left the clock running ('$(rowval ci_runners.empty_since)') — the next empty read would inherit it"

# ── 7. an unreadable pool is its own, quieter condition ────────────────────
reset; pool 2 ""; row ci_runners.unreadable_since "$((NOW - 660))"
run
[ "$(nalerts)" = 1 ] && ok || bad "7a want exactly one unreadable alert, got $(nalerts): $(alerts)"
case "$(alerts)" in *"--id ci-runners-unreadable"*) ok ;; *) bad "7b the unreadable alert carried the wrong id: $(alerts)" ;; esac
case "$(alerts)" in *"--severity warn"*) ok ;; *) bad "7c a read we could not make paged as if the pool were empty: $(alerts)" ;; esac
case "$(alerts)" in *ci-runners-empty*) bad "7d rc 2 produced the 'no runners' alert — a broken token now pages the fleet: $(alerts)" ;; *) ok ;; esac
[ -z "$(rowval ci_runners.empty_since)" ] && ok \
  || bad "7e rc 2 started the EMPTY streak: $(rowval ci_runners.empty_since)"

# ── 8. rc 2 never retracts an open empty alert ─────────────────────────────
reset; pool 2 ""; row ci_runners.empty_since "$((NOW - 900)):fired"
run
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 900)):fired" ] && ok \
  || bad "8a a failed read rewrote the open outage row: $(rowval ci_runners.empty_since)"
case "$(alerts)" in *"--resolve"*ci-runners-empty*) bad "8b a read we could not make retracted a true alert: $(alerts)" ;; *) ok ;; esac

# ── 16. a read that WORKS closes an open unreadable condition ──────────────
reset; pool 1 "$POOL_EMPTY"; row ci_runners.unreadable_since "$((NOW - 660)):fired"
run
case "$(alerts)" in *"--resolve"*"--id ci-runners-unreadable"*) ok ;; *) bad "16a an answered read left the unreadable condition open: $(alerts)" ;; esac
[ "$(rowval ci_runners.unreadable_since)" = 0 ] && ok \
  || bad "16b the unreadable row survived a working read: $(rowval ci_runners.unreadable_since)"

# ── 9. a worker that does not answer means no alerting at all ──────────────
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
: > "$FIX/d1-down"
run
[ "$RC" = 0 ] && ok || bad "9a a D1 outage made the tick exit $RC (want 0 — the fleet keeps running)"
[ "$(nalerts)" = 0 ] && ok || bad "9b the lane alerted on a streak it could not read: $(alerts)"
[ ! -f "$FIX/settings-writes" ] && ok || bad "9c the lane claimed a settings write during a D1 outage: $(cat "$FIX/settings-writes")"

# ── 10. the hold is a knob, and 0 turns the check off ──────────────────────
reset; pool 1 "$POOL_EMPTY"; HOLD=1; row ci_runners.empty_since "$((NOW - 120))"
run
[ "$(nalerts)" = 1 ] && ok || bad "10a CI_RUNNERS_ALERT_HOLD_MIN=1 did not fire on a two-minute streak: $(alerts)"

reset; pool 1 "$POOL_EMPTY"; HOLD=0; row ci_runners.empty_since "$((NOW - 3600))"
run
[ "$(ncalls)" = 0 ] && ok || bad "10b CI_RUNNERS_ALERT_HOLD_MIN=0 still read the pool: $(cat "$FIX/ci-calls")"
[ "$(nalerts)" = 0 ] && ok || bad "10c CI_RUNNERS_ALERT_HOLD_MIN=0 still alerted: $(alerts)"

# ── 11. a read we cannot even run is unreadable, never empty ───────────────
reset; rm -f "$H/bin/ci-runners-status.sh"
row ci_runners.unreadable_since "$((NOW - 660))"
run
[ "$RC" = 0 ] && ok || bad "11a a missing status script made the tick exit $RC"
case "$(alerts)" in *ci-runners-empty*) bad "11b a missing status script read as an empty pool: $(alerts)" ;; *) ok ;; esac
case "$(alerts)" in *"--id ci-runners-unreadable"*) ok ;; *) bad "11c a missing status script raised nothing at all: $(alerts)" ;; esac
[ -z "$(rowval ci_runners.empty_since)" ] && ok \
  || bad "11d a missing status script started the EMPTY streak: $(rowval ci_runners.empty_since)"

reset; rm -f "$H/bin/ci-runners-status.sh"
run
S=$(rowval ci_runners.unreadable_since)
[ -n "$S" ] && [ "$S" -ge "$NOW" ] 2>/dev/null && ok \
  || bad "11e a missing status script did not start the unreadable clock ('$S')"

# ── 12. the lane's off switch covers the pool check ────────────────────────
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 3600))"
: > "$H/flags/lane-off-testhost-tick"
run
[ "$RC" = 0 ] && ok || bad "12a a gated tick exited $RC (a skip is not a failure — cron mails on nonzero)"
[ "$(ncalls)" = 0 ] && ok || bad "12b a gated tick still read the pool: $(cat "$FIX/ci-calls")"
[ "$(nalerts)" = 0 ] && ok || bad "12c a gated tick still alerted: $(alerts)"

# ── 14. the pool condition does not depend on the Fly half ─────────────────
# A machine whose state cannot be read is the tick's OTHER failure mode, and it
# must not swallow this one: the pool check runs first and on its own evidence.
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
: > "$FIX/status-fails"
run
[ "$(nalerts)" = 1 ] && ok || bad "14 an unreadable Fly machine suppressed the pool alert: $(alerts)"

# ── 15. send first, stamp second ───────────────────────────────────────────
# A row stamped as alerted by a send that never left the box is an outage
# nobody hears about, for ever.
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
: > "$FIX/alert-fails"
run
case "$(rowval ci_runners.empty_since)" in *:fired) bad "15a a failed send was stamped as fired: $(rowval ci_runners.empty_since)" ;; *) ok ;; esac
rm -f "$FIX/alert-fails"
run
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 660)):fired" ] && ok \
  || bad "15b the retry after a failed send did not stamp: $(rowval ci_runners.empty_since)"

echo "ci-runners-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
