#!/bin/bash
# tests/ci-runners-alert.bh-1323-test.sh — BH-1323: the pool-empty page has to
# be true on the fleet we actually run on.
#
# WHY THIS EXISTS. `cmd_ci_runners` in bin/testhost-tick.sh pages critical when
# the Fly bh-ci pool reads empty past its hold, and its body used to end with
# "flip the CI_RUNNER repo variable back to \"ubuntu-16-core\"". Two things
# broke that sentence on 2026-09-22:
#
#   - CI moved to MonkCI, so "Harness CI jobs QUEUE instead of failing … the
#     drain stops merging" is only true while CI_RUNNER names the Fly pool. On
#     MonkCI the gate is somewhere else entirely and an empty pool is the
#     FALLBACK fleet being down, which is a different-sized problem;
#   - bin/ci-runner-known.sh now refuses "ubuntu-16-core" on the lint job, so an
#     operator who followed this page verbatim turned the next run red.
#
# A critical page that tells the operator to do the thing the gate refuses is
# worse than no page. This suite drives the REAL tick and reads the REAL
# emitted alert argv, then runs the REAL guard over every value the body
# recommends — so the page and the guard cannot drift apart without a red
# suite. Assertions are on the recorded argv of the stubbed bin/lane-alert.sh,
# never on the lane's source text (D3).
#
# The mechanics BH-1210 pinned (severity, id, one send per streak, send-then-
# stamp) are re-asserted here rather than assumed: this ticket changes words
# inside that alert and the cheapest way to prove it changed only the words is
# to measure the behaviour again.
#
# Run from anywhere: tests/ci-runners-alert.bh-1323-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TICK="$DIR/bin/testhost-tick.sh"
KNOWN="$DIR/bin/ci-runner-known.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$T/fakebin" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
# COPIED into the scratch tree so $(dirname "$0") resolves there: a fallback to
# the checkout's own bin/ would shell out to gh and hit the network.
scratch_install_closure bin/testhost-tick.sh "$H" >/dev/null || { echo "FAIL: could not install the tick's closure"; exit 1; }
# ONE clock read for the whole file; every age below is derived from it.
NOW=$(date -u '+%s')

POOL_OK='{"repo":"example-org/cromford","label":"bh-ci","total":74,"online":74,"idle":70,"busy":4,"offline":0}'
POOL_EMPTY='{"repo":"example-org/cromford","label":"bh-ci","total":74,"online":0,"idle":0,"busy":0,"offline":74}'

cat > "$H/bin/jobs-client.sh" <<'STUB'
JOBS_BOX=fixture
flag_sync()  { return 1; }
setting_get() {
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
setting_set() {
  printf '%s' "$2" > "$FIX/settings/$1"
  return 0
}
STUB

cat > "$H/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ci-calls"
[ -f "$FIX/ci-body" ] && cat "$FIX/ci-body"
exit "$(cat "$FIX/ci-rc" 2>/dev/null || echo 0)"
STUB

# The emitter: argv recorded, one line per call. $FIX/alert-fails makes the send
# fail, which is how the send-then-stamp ordering is measured.
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
[ -f "$FIX/alert-fails" ] && exit 1
exit 0
STUB

# The Fly half of the tick is not this suite's subject, but it still has to
# answer or the tick stops before the interesting part.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
case "$*" in
  *"machine list"*|*"machines list"*) cat "$FIX/machines.json"; exit 0 ;;
  *"machine status"*|*"machines status"*)
    printf 'Machine ID: 873eddb0433018\nState: started\n\nVM\n CPU Kind │ performance\n vCPUs │ 16\n'
    exit 0 ;;
  *"ssh console"*) echo "TESTHOST_BUSY 0"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/* "$H/bin/ci-runners-status.sh" "$H/bin/lane-alert.sh"
printf '[{"id":"873eddb0433018","name":"testhost-1","state":"started"}]\n' > "$FIX/machines.json"
export FIX

run() {
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    TESTHOST_APP=bh-testhost-fixture \
    CI_RUNNERS_ALERT_HOLD_MIN="${HOLD:-10}" \
    bash "$H/bin/testhost-tick.sh" "$@" 2>&1); RC=$?
}
reset() {
  rm -f "$FIX/ci-calls" "$FIX/alert-calls" "$FIX/alert-fails" "$FIX"/settings/*
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  pool 0 "$POOL_OK"
  # A use one minute old keeps the Fly half inside its idle window.
  printf '%s' "$((NOW - 60))" > "$FIX/settings/testhost.last_used"
  HOLD=10
}
pool()    { printf '%s\n' "$1" > "$FIX/ci-rc"; printf '%s\n' "$2" > "$FIX/ci-body"; }
row()     { printf '%s' "$2" > "$FIX/settings/$1"; }
rowval()  { cat "$FIX/settings/$1" 2>/dev/null; }
alerts()  { cat "$FIX/alert-calls" 2>/dev/null; }
nalerts() { if [ -f "$FIX/alert-calls" ]; then wc -l < "$FIX/alert-calls" | tr -d ' '; else echo 0; fi; }

# ── the page itself ─────────────────────────────────────────────────────────
# One real empty-pool outage past the hold. Everything below reads $BODY, which
# is the argv the lane actually handed the emitter.
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
run
BODY=$(alerts)
[ "$(nalerts)" = 1 ] && ok || bad "0a want exactly one alert past the hold, got $(nalerts): $BODY"
[ -n "$BODY" ] || { echo "FAIL: 0b the empty-pool alert never fired, so there is no page to check"; echo "ci-runners-alert-1323: $PASS passed, $((FAIL+1)) failed"; exit 1; }
ok

# 1. THE PAGE MAY NOT NAME A VALUE THE GATE REFUSES.
case "$BODY" in
  *ubuntu-16-core*) bad "1 the page still tells the operator to flip CI_RUNNER to \"ubuntu-16-core\", which bin/ci-runner-known.sh now refuses on the lint job: $BODY" ;;
  *) ok ;;
esac

# 2. EVERY QUOTED VALUE THE PAGE RECOMMENDS GOES THROUGH THE REAL GUARD.
# Not a string match against a list this file keeps — the production guard's own
# exit code. If someone adds a fleet to the page, the guard has to know it too.
#
# THE PAGE MUST QUOTE ONE FLEET VALUE AT A TIME, and that is a constraint on the
# page, not a defect here. The extractor below pulls every "…" run out of the
# body, so a page that also spelled out the Fly pool's ["self-hosted","linux",
# "bh-ci"] would yield "self-hosted", "linux" and "bh-ci" as three candidates
# and this assertion would go red on correct copy. Name the second fleet in
# prose (it is the pool this alert is already about) or teach this block to skip
# a bracketed array before you quote it.
if [ -x "$KNOWN" ]; then
  CANDIDATES=$(printf '%s' "$BODY" | grep -o '"[^"]*"' | sort -u)
  [ -n "$CANDIDATES" ] && ok || bad "2a the page recommends no CI_RUNNER value at all — an operator reading it has nothing to set"
  BADVALS=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    "$KNOWN" "$c" >/dev/null 2>&1 || BADVALS="$BADVALS $c"
  done <<< "$CANDIDATES"
  [ -z "$BADVALS" ] && ok || bad "2b the page recommends CI_RUNNER values the guard refuses:$BADVALS"
else
  bad "2a bin/ci-runner-known.sh is missing or not executable — the page cannot be checked against the guard"
  bad "2b bin/ci-runner-known.sh is missing or not executable"
fi

# 3. IT NAMES THE CURRENT FLEET AND THE KNOB THAT SILENCES A DELIBERATELY COLD
# POOL. After the warm-minimum shrink (docs/CI-RUNNERS.md) an empty pool is the
# normal state, and an operator who cannot turn the page off mutes the lane.
case "$BODY" in *monkci-ubuntu-24.04-4*) ok ;; *) bad "3a the page does not name the current fleet, so it reads as if the gate were down: $BODY" ;; esac
case "$BODY" in *CI_RUNNERS_ALERT_HOLD_MIN*) ok ;; *) bad "3b the page does not name the hold knob, so a pool that is cold on purpose pages for ever: $BODY" ;; esac

# 4. THE "THE DRAIN STOPPED" CONSEQUENCE IS CONDITIONAL, NOT ASSERTED.
# It holds while CI_RUNNER names the Fly pool and is false while it names
# MonkCI. Split the body into sentences and require the one carrying the
# consequence to carry its condition too.
SENTENCE=$(printf '%s' "$BODY" | sed 's/\. /.\n/g' | grep 'drain stops merging')
if [ -n "$SENTENCE" ]; then
  ok
  case "$SENTENCE" in
    *CI_RUNNER*) ok ;;
    *) bad "4b the page states the drain has stopped without saying it depends on CI_RUNNER — on MonkCI that is false: $SENTENCE" ;;
  esac
else
  bad "4a the page no longer explains what an empty pool costs: $BODY"
  bad "4b (no consequence sentence to check for its condition)"
fi

# ── 5. the mechanics BH-1210 pinned, re-measured ────────────────────────────
case "$BODY" in *"--severity critical"*) ok ;; *) bad "5a the pool alert stopped being critical: $BODY" ;; esac
case "$BODY" in *"--id ci-runners-empty"*) ok ;; *) bad "5b the pool alert lost its stable condition id: $BODY" ;; esac
case "$BODY" in *"0 of 74"*) ok ;; *) bad "5c the page lost the counts from the body that was read: $BODY" ;; esac
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 660)):fired" ] && ok \
  || bad "5d the streak row was not stamped as fired: $(rowval ci_runners.empty_since)"

# one send per outage, however long it runs
run; run
[ "$(nalerts)" = 1 ] && ok || bad "5e two more ticks of the same outage sent $(nalerts) alerts (want 1): $(alerts)"

# send first, stamp second: a row stamped by a send that never left the box is
# an outage nobody hears about.
reset; pool 1 "$POOL_EMPTY"; row ci_runners.empty_since "$((NOW - 660))"
: > "$FIX/alert-fails"
run
case "$(rowval ci_runners.empty_since)" in
  *:fired) bad "5f a failed send was stamped as fired: $(rowval ci_runners.empty_since)" ;;
  *) ok ;;
esac
rm -f "$FIX/alert-fails"
run
[ "$(rowval ci_runners.empty_since)" = "$((NOW - 660)):fired" ] && ok \
  || bad "5g the retry after a failed send did not stamp: $(rowval ci_runners.empty_since)"

echo "ci-runners-alert-1323: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
