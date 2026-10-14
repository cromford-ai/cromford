#!/bin/bash
# tests/testhost-tick-cron-path.bh-6061-test.sh — the testhost tick finds
# flyctl under cron's PATH, alerts on an unknown-state streak, and answers the
# read-only `idle` verb (BH-6061).
#
# WHY. Cron's PATH is /usr/bin:/bin. `_th_fly` checked `command -v flyctl`
# BEFORE it put /root/.fly/bin on PATH, so every Fly call from cron returned
# 127, every tick read `state=unknown`, and the tick logged "nothing to stop"
# for 13 days while the host billed. Nothing alerted.
#
# WHAT THIS PINS. The REAL bin/testhost-tick.sh against a scratch $HARNESS:
#   T1 with PATH=/usr/bin:/bin and flyctl only in $HOME/.fly/bin, `state`
#      reads the machine state (the reproduction: main prints `unknown`);
#   T2 two unknown ticks raise nothing and count the streak;
#   T3 the third raises exactly one testhost-state-unknown alert that names
#      the cause, and the fourth and fifth raise no second one;
#   T4 an auth failure is named as one, and the token is in no alert or log;
#   T5 a known state after a fired streak resolves it once and clears it;
#   T6 a flyctl on PATH wins over $HOME/.fly/bin (PATH first);
#   T7 `idle <mid>` prints idle seconds, 0 when busy, `unknown` rc 2 when it
#      cannot tell, probes that machine, and writes nothing.
#
# Run from anywhere: tests/testhost-tick-cron-path.bh-6061-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# T0. The reproduction needs a /usr/bin with no flyctl of its own.
if [ -n "$(env -i PATH=/usr/bin:/bin sh -c 'command -v flyctl' 2>/dev/null)" ]; then
  echo "SKIP: flyctl on /usr/bin"; exit 0
fi

FIX="$T/fix"; H="$T/h"; HOMEDIR="$T/home"; BARE="$T/barehome"
mkdir -p "$FIX/settings" "$T/fakebin" "$HOMEDIR/.fly/bin" "$BARE" \
  "$H/bin" "$H/catalog" "$H/flags" "$H/logs" "$H/state" "$H/env"
NOW=$(date -u '+%s')

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
echo '{"repo":"example-org/cromford","label":"bh-ci","total":4,"online":4,"idle":4,"busy":0,"offline":0}'
exit 0
STUB
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
exit 0
STUB
chmod +x "$H/bin/ci-runners-status.sh" "$H/bin/lane-alert.sh"
scratch_install_closure bin/testhost-tick.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$(rendered_registry)" "$H/catalog/lanes.json"
printf 'FLY_API_TOKEN=FlyV1 fm2_fixture\n' > "$H/env/fly.env"

# The flyctl stub. $FIX/fly-mode picks the answer: ok (default) or auth.
# `ssh console` answers from $FIX/busy (a TESTHOST_BUSY count, or `fail`).
STUBSRC="$T/flyctl.stub"
cat > "$STUBSRC" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
[ -n "${MARK:-}" ] && : > "$FIX/$MARK"
if [ "$(cat "$FIX/fly-mode" 2>/dev/null)" = auth ]; then
  echo "Error: not authenticated (token FlyV1 fm2_fixture rejected)"; exit 1
fi
case "$*" in
  *"machine list"*) echo '[{"id":"0e1fixture","name":"testhost-1","state":"started"}]'; exit 0 ;;
  *"machine status"*) printf 'Machine ID: 0e1fixture\nState: %s\n' "$(cat "$FIX/state" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*)
    cat > /dev/null
    b=$(cat "$FIX/busy" 2>/dev/null || echo 0)
    [ "$b" = fail ] && { echo "Error: ssh: connect failed"; exit 1; }
    echo "TESTHOST_BUSY $b"; exit 0 ;;
esac
exit 0
STUB
install -m 755 "$STUBSRC" "$HOMEDIR/.fly/bin/flyctl"
export FIX

# run <home> <path> <verb...> — the cron environment: env -i, a bare PATH.
run() {
  local home="$1" path="$2"; shift 2
  OUT=$(env -i PATH="$path" HOME="$home" HARNESS="$H" FIX="$FIX" LANE_START_SPREAD_S=0 \
    TESTHOST_APP=bh-testhost-fixture ${MARK:+MARK=$MARK} \
    bash "$TICK" "$@" 2>&1 </dev/null); RC=$?
}
reset() {
  rm -f "$FIX/fly-calls" "$FIX/alert-calls" "$FIX/fly-mode" "$FIX/state" "$FIX/busy" "$FIX"/settings/* "$FIX"/mark-*
  rm -f "$H/logs/testhost-tick.log" "$H/state/testhost-tick/unknown-streak"
  printf '%s' "$NOW" > "$FIX/settings/testhost.last_used"
}
alerts_for() { local n; n=$(grep -c -- "--id $1 " "$FIX/alert-calls" 2>/dev/null); echo "${n:-0}"; }
streak() { cat "$H/state/testhost-tick/unknown-streak" 2>/dev/null; }

# ── T1. the reproduction: cron PATH, flyctl only in ~/.fly/bin ─────────────
reset
run "$HOMEDIR" /usr/bin:/bin state
[ "$OUT" = started ] && ok || bad "T1 under cron's PATH with flyctl in \$HOME/.fly/bin, state printed '$OUT' (rc $RC), want 'started'"

# ── T2. no flyctl anywhere: two unknown ticks, no alert yet ────────────────
reset
run "$BARE" /usr/bin:/bin; run "$BARE" /usr/bin:/bin
[ "$(alerts_for testhost-state-unknown)" = 0 ] && ok || bad "T2 two unknown ticks alerted: $(cat "$FIX/alert-calls" 2>/dev/null)"
case "$(streak)" in 2\ *) ok ;; *) bad "T2 the streak after two unknown ticks is '$(streak)', want it to start with 2" ;; esac

# ── T3. the third tick alerts once, naming the cause; 4 and 5 stay quiet ──
run "$BARE" /usr/bin:/bin
[ "$(alerts_for testhost-state-unknown)" = 1 ] && ok || bad "T3 the third unknown tick sent $(alerts_for testhost-state-unknown) alerts, want 1: $(cat "$FIX/alert-calls" 2>/dev/null)"
grep -- "--id testhost-state-unknown " "$FIX/alert-calls" 2>/dev/null | grep -q 'flyctl not found' \
  && ok || bad "T3 the alert does not name the cause 'flyctl not found': $(cat "$FIX/alert-calls" 2>/dev/null)"
grep -- "--id testhost-state-unknown " "$FIX/alert-calls" 2>/dev/null | grep -q '3 ' \
  && ok || bad "T3 the alert does not carry the streak count 3: $(cat "$FIX/alert-calls" 2>/dev/null)"
run "$BARE" /usr/bin:/bin; run "$BARE" /usr/bin:/bin
[ "$(alerts_for testhost-state-unknown)" = 1 ] && ok || bad "T3 ticks 4 and 5 sent a second alert: $(cat "$FIX/alert-calls" 2>/dev/null)"

# ── T5. a known state resolves the fired streak once and clears it ─────────
run "$HOMEDIR" /usr/bin:/bin
[ "$(grep -c -- '--resolve --id testhost-state-unknown' "$FIX/alert-calls" 2>/dev/null)" = 1 ] \
  && ok || bad "T5 a started tick after a fired streak sent no single resolve: $(cat "$FIX/alert-calls" 2>/dev/null)"
[ -e "$H/state/testhost-tick/unknown-streak" ] && bad "T5 the streak file survived a known state: $(streak)" || ok
run "$HOMEDIR" /usr/bin:/bin
[ "$(grep -c -- '--resolve' "$FIX/alert-calls" 2>/dev/null)" = 1 ] \
  && ok || bad "T5 a known state with no fired streak sent a resolve: $(cat "$FIX/alert-calls" 2>/dev/null)"
# A streak that never fired is cleared with no resolve call.
reset
run "$BARE" /usr/bin:/bin; run "$HOMEDIR" /usr/bin:/bin
[ -s "$FIX/alert-calls" ] && bad "T5 an unfired streak sent an alert call: $(cat "$FIX/alert-calls")" || ok
[ -e "$H/state/testhost-tick/unknown-streak" ] && bad "T5 an unfired streak was not cleared" || ok

# ── T4. an auth failure is named, and the token never leaks ────────────────
reset
echo auth > "$FIX/fly-mode"
run "$HOMEDIR" /usr/bin:/bin; run "$HOMEDIR" /usr/bin:/bin; run "$HOMEDIR" /usr/bin:/bin
[ "$(alerts_for testhost-state-unknown)" = 1 ] && ok || bad "T4 three auth-failure ticks sent $(alerts_for testhost-state-unknown) alerts, want 1"
grep -- "--id testhost-state-unknown " "$FIX/alert-calls" 2>/dev/null | grep -q 'auth failure' \
  && ok || bad "T4 the alert does not say 'auth failure': $(cat "$FIX/alert-calls" 2>/dev/null)"
if grep -q 'fm2_fixture' "$FIX/alert-calls" "$H/logs/testhost-tick.log" "$H/state/testhost-tick/unknown-streak" 2>/dev/null; then
  bad "T4 the token value is in the alert text, the log or the streak file"
else ok; fi

# ── T6. PATH first: a flyctl on PATH wins over $HOME/.fly/bin ──────────────
reset
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
: > "$FIX/mark-path"
case "$*" in
  *"machine list"*) echo '[{"id":"0e1fixture"}]' ;;
  *"machine status"*) echo 'State: stopped' ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/flyctl"
MARK=mark-home run "$HOMEDIR" "$T/fakebin:/usr/bin:/bin" state
[ "$OUT" = stopped ] && ok || bad "T6 with flyctl on PATH and in \$HOME/.fly/bin, state printed '$OUT' — the PATH one was not used"
[ -e "$FIX/mark-path" ] && ok || bad "T6 the PATH flyctl was never called"
[ -e "$FIX/mark-home" ] && bad "T6 the \$HOME/.fly/bin flyctl was called although PATH has one" || ok
rm -f "$T/fakebin/flyctl"

# ── T7. the read-only idle verb ────────────────────────────────────────────
reset
printf '%s' "$((NOW - 1000))" > "$FIX/settings/testhost.last_used"
echo 0 > "$FIX/busy"
run "$HOMEDIR" /usr/bin:/bin idle 0e1fixture
if [ "$RC" = 0 ] && [[ "$OUT" =~ ^[0-9]+$ ]] && [ "$OUT" -ge 1000 ] && [ "$OUT" -le 1010 ]; then ok
else bad "T7a idle with last_used NOW-1000 and an idle probe printed '$OUT' rc $RC, want ~1000 rc 0"; fi
grep -q -- '--machine 0e1fixture' "$FIX/fly-calls" 2>/dev/null && ok || bad "T7a the probe did not target --machine 0e1fixture: $(cat "$FIX/fly-calls" 2>/dev/null)"
[ "$(cat "$FIX/settings/testhost.last_used")" = "$((NOW - 1000))" ] && ok || bad "T7a idle changed testhost.last_used"

echo 3 > "$FIX/busy"
run "$HOMEDIR" /usr/bin:/bin idle 0e1fixture
[ "$RC" = 0 ] && [ "$OUT" = 0 ] && ok || bad "T7b a busy host printed '$OUT' rc $RC, want '0' rc 0"
[ "$(cat "$FIX/settings/testhost.last_used")" = "$((NOW - 1000))" ] && ok || bad "T7b idle on a busy host refreshed testhost.last_used — it must write nothing"

echo fail > "$FIX/busy"
run "$HOMEDIR" /usr/bin:/bin idle 0e1fixture
[ "$RC" = 2 ] && [ "$OUT" = unknown ] && ok || bad "T7c a failed probe printed '$OUT' rc $RC, want 'unknown' rc 2"

echo 0 > "$FIX/busy"; rm -f "$FIX/settings/testhost.last_used"
run "$HOMEDIR" /usr/bin:/bin idle 0e1fixture
[ "$RC" = 2 ] && [ "$OUT" = unknown ] && ok || bad "T7d no last_used row printed '$OUT' rc $RC, want 'unknown' rc 2"
[ -e "$FIX/settings/testhost.last_used" ] && bad "T7d idle wrote a testhost.last_used row" || ok
if grep -qE 'machine (stop|start)' "$FIX/fly-calls" 2>/dev/null; then bad "T7 idle sent a stop or a start: $(cat "$FIX/fly-calls")"; else ok; fi

echo "testhost-tick-cron-path: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
