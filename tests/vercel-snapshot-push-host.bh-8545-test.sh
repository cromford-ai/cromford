#!/bin/bash
# tests/vercel-snapshot-push-host.bh-8545-test.sh — THE SNAPSHOT PUSH TARGETS
# THE FLEET.CONF TAILNET IP, AND A FAIL STREAK WRITES ONE ALERTS LINE (BH-8545).
#
# bin/vercel-deploy-snapshot.sh pushed state/vercel-deploy-status.json to
# `root@<box name>`. The project-1 box's tailnet name pointed at a dead device,
# so every push timed out, the box's snapshot froze, and the failure showed only
# in logs/vercel-snapshot.log. The push now resolves the host through
# bin/box-host.sh (fleet.conf column 7), and VERCEL_PUSH_FAIL_STREAK failures in
# a row for one box write ONE ALERTS line that names the box, the host and the
# ssh error.
#
# Driven: the REAL lane script, with the REAL bin/box-for.sh, bin/box-host.sh
# and bin/fleet-conf.sh on a fixture fleet.conf. Stubs first on PATH: `curl`
# (the Vercel API, answered from fixtures, every URL logged), `npx` (the CLI
# refresh, logged, must not run) and `ssh` (records argv + stdin, never
# connects). 0 real network.
#
#   S1 dead name: ssh gets root@192.0.2.10, never root@<name>; pushed: <box>
#   S2 no IP column: ssh gets root@<box name> (today's behavior)
#   S3 streak: runs 1,2 -> 0 lines; run 3 -> 1 line; run 4 -> still 1; count 1..4
#   S4 alert fields + log token; empty stderr rc 124 -> "no ssh output (rc 124)"
#   S5 per box + reset: A 3 fails, B 2 -> one line, for A; reset; stderr on rc 0
#   S6 knob: 1 -> line on run 1; abc and 0 -> read as 3; garbage count -> 1
#   S7 error cut: 300-char stderr with a CR -> 200 chars, no CR; knob 40 -> 40;
#      knob x -> 200
#   B  budget: curl saw only api.vercel.com, npx never ran
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vercel-snapshot-push-host.bh-8545-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

H="$T/h"; FB="$T/fakebin"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$FB" "$T/ssh-in"
scratch_install_closure bin/vercel-deploy-snapshot.sh "$H" >/dev/null || bad "setup: cannot install the lane script"
scratch_install_closure bin/box-for.sh "$H" >/dev/null || bad "setup: cannot install bin/box-for.sh"
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "setup: cannot install bin/fleet-conf.sh"
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || bad "setup: cannot install bin/alert-line.sh"
if [ -f "$DIR/bin/box-host.sh" ]; then
  scratch_install_closure bin/box-host.sh "$H" >/dev/null || bad "setup: cannot install bin/box-host.sh"
fi

# Vercel CLI auth fixture: a fixture token, expiry far in the future.
jq -nc --argjson e "$(( $(date +%s) + 86400 * 365 ))" '{token:"tok-fixture-1", expiresAt:$e}' > "$T/auth.json"

cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$CURL_LOG"
case "$URL" in
  https://api.vercel.com/v4/aliases/*) echo '{"deploymentId":"dpl_fixture_s"}' ;;
  https://api.vercel.com/v13/deployments/*) echo '{"createdAt":1700000000000,"gitSource":{"sha":"a1b2c3d4e5f6"}}' ;;
  https://api.vercel.com/v6/deployments*) echo '{"deployments":[]}' ;;
  *) exit 7 ;;
esac
STUB
cat > "$FB/npx" <<'STUB'
#!/bin/bash
echo "npx $*" >> "$CURL_LOG"
exit 0
STUB
# ssh stub. SSH_OK = space list of hosts that succeed; any other host fails
# with SSH_RC (default 255) and SSH_ERR on stderr (empty SSH_ERR = no stderr).
# SSH_WARN=1 writes a warning line on stderr for a host that succeeds.
cat > "$FB/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
HOST=""; for a in "$@"; do case "$a" in root@*) HOST=${a#root@}; break ;; esac; done
cat > "$SSH_IN/$HOST"
case " ${SSH_OK:-} " in
  *" $HOST "*) [ "${SSH_WARN:-0}" = 1 ] && echo "Warning: Permanently added '$HOST' (ED25519) to the list of known hosts." >&2; exit 0 ;;
esac
[ -n "${SSH_ERR:-}" ] && printf '%s\n' "${SSH_ERR//%h/$HOST}" >&2
exit "${SSH_RC:-255}"
STUB
chmod +x "$FB/curl" "$FB/npx" "$FB/ssh"

DEAD=box-fixture-dead
DEADIP=192.0.2.10
NOIP=box-fixture-noip
B2=box-fixture-two
B2IP=198.51.100.20
ERRTXT='ssh: connect to host %h port 22: Connection timed out'

# conf <fleet rows...> — fleet.conf + vercel.conf for the projects in the rows.
conf() {
  printf '# fixture fleet.conf (BH-8545)\n' > "$T/fleet.conf"
  : > "$H/vercel.conf"
  local r p
  for r in "$@"; do
    printf '%s\n' "$r" >> "$T/fleet.conf"
    p=${r%% *}
    printf '%s team_fixture prj_fixture_%s %s.example.test\n' "$p" "$p" "$p" >> "$H/vercel.conf"
  done
}
reset_state() { scratch_rm "$H/state/vercel-snapshot-push-fail"; rm -f "$T/ssh-in"/*; : > "$H/logs/ALERTS.log"; : > "$H/logs/vercel-snapshot.log"; : > "$T/ssh.log"; }
# run_snap — one run of the real lane script. Extra env goes before the call.
run_snap() {
  env -u VERCEL_PUSH_FAIL_STREAK -u VERCEL_PUSH_ERR_CHARS PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$T/fleet.conf" REGISTRY_SOURCE=file \
      LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/no-registry.json" JOBS_URL='' \
      VERCEL_CLI_AUTH="$T/auth.json" CURL_LOG="$T/curl.log" SSH_LOG="$T/ssh.log" SSH_IN="$T/ssh-in" \
      "$@" bash "$H/bin/vercel-deploy-snapshot.sh" 2>>"$T/stderr"
}
alerts() { grep -c '\[vercel-snapshot\] push to' "$H/logs/ALERTS.log" 2>/dev/null; }
alerts_for() { grep -c "\[vercel-snapshot\] push to $1 failed" "$H/logs/ALERTS.log" 2>/dev/null; }
count_of() { cat "$H/state/vercel-snapshot-push-fail/$1" 2>/dev/null || echo none; }
lastlog() { tail -1 "$H/logs/vercel-snapshot.log"; }

ROW_DEAD="proj-fixture-a example-org/proj-fixture-a https://a.example.test /api/board 2 $DEAD $DEADIP"
ROW_NOIP="proj-fixture-n example-org/proj-fixture-n https://n.example.test /api/board 3 $NOIP"
ROW_B2="proj-fixture-b example-org/proj-fixture-b https://b.example.test /api/board 4 $B2 $B2IP"
: > "$T/curl.log"; : > "$T/stderr"

# ---------- S1: a dead tailnet name, a live IP --------------------------------
conf "$ROW_DEAD"; reset_state
run_snap SSH_OK="$DEADIP" SSH_ERR="$ERRTXT"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1 rc 0 (got $RC)"
grep -q "root@$DEADIP " "$T/ssh.log" && ok || bad "S1 ssh got root@$DEADIP (ssh log: $(cat "$T/ssh.log"))"
! grep -q "root@$DEAD " "$T/ssh.log" && ok || bad "S1 ssh never got root@$DEAD (ssh log: $(cat "$T/ssh.log"))"
L=$(lastlog)
[[ "$L" == *"pushed: $DEAD "* ]] && [[ "$L" != *FAILED:* ]] && ok || bad "S1 log line has 'pushed: $DEAD' and no FAILED (got '$L')"
jq -e '.projects["proj-fixture-a"].serving.id == "dpl_fixture_s"' "$T/ssh-in/$DEADIP" >/dev/null 2>&1 \
  && ok || bad "S1 the stub ssh received the snapshot JSON on stdin"
[ -z "$(find "$H/state" -maxdepth 1 -name '.vercel-push-err*')" ] \
  && ok || bad "S1 no ssh stderr temp file left in state/ ($(ls -a "$H/state"))"
[ "$(alerts)" = 0 ] && ok || bad "S1 a success writes no ALERTS line"

# ---------- S2: a box with no IP column falls back to its name ----------------
conf "$ROW_NOIP"; reset_state
run_snap SSH_OK="$NOIP"
grep -q "root@$NOIP " "$T/ssh.log" && ok || bad "S2 ssh got root@$NOIP (ssh log: $(cat "$T/ssh.log"))"
[[ "$(lastlog)" == *"pushed: $NOIP "* ]] && ok || bad "S2 pushed: $NOIP (got '$(lastlog)')"

# ---------- S3: a streak of 4, one alert at 3 ---------------------------------
conf "$ROW_DEAD"; reset_state
for n in 1 2 3 4; do
  run_snap SSH_ERR="$ERRTXT"
  [ "$(count_of "$DEAD")" = "$n" ] && ok || bad "S3 run $n: count file reads $n (got $(count_of "$DEAD"))"
  want=0; [ "$n" -ge 3 ] && want=1
  [ "$(alerts)" = "$want" ] && ok || bad "S3 run $n: $want ALERTS line(s) (got $(alerts): $(cat "$H/logs/ALERTS.log"))"
done

# ---------- S4: the alert line and the log token name box, host, error -------
A=$(grep '\[vercel-snapshot\] push to' "$H/logs/ALERTS.log" | head -1)
[[ "$A" == *"[vercel-snapshot] push to $DEAD failed 3 runs in a row: host $DEADIP: ssh: connect to host $DEADIP port 22: Connection timed out"* ]] \
  && ok || bad "S4 the ALERTS line names box, host and the ssh error (got '$A')"
[[ "$(lastlog)" == *"FAILED:"*" push:$DEAD@$DEADIP"* ]] && ok || bad "S4 log token push:$DEAD@$DEADIP (got '$(lastlog)')"
reset_state
for n in 1 2 3; do run_snap SSH_ERR= SSH_RC=124; done
A=$(grep '\[vercel-snapshot\] push to' "$H/logs/ALERTS.log" | head -1)
[[ "$A" == *"push to $DEAD failed 3 runs in a row: host $DEADIP: no ssh output (rc 124)" ]] \
  && ok || bad "S4 empty stderr with rc 124 -> 'no ssh output (rc 124)' (got '$A')"

# ---------- S5: per box, and a success resets the streak ----------------------
conf "$ROW_DEAD" "$ROW_B2"; reset_state
run_snap SSH_ERR="$ERRTXT"                  # A 1, B 1
run_snap SSH_ERR="$ERRTXT"                  # A 2, B 2
run_snap SSH_OK="$B2IP" SSH_ERR="$ERRTXT"   # A 3 (alert), B ok -> reset
[ "$(alerts_for "$DEAD")" = 1 ] && [ "$(alerts_for "$B2")" = 0 ] && ok \
  || bad "S5 A at 3 and B at 2 then ok -> one line, for A (got $(cat "$H/logs/ALERTS.log"))"
[ "$(count_of "$B2")" = none ] && ok || bad "S5 B's success deleted its count file (got $(count_of "$B2"))"
run_snap SSH_OK="$DEADIP $B2IP" SSH_WARN=1  # both ok, with stderr on rc 0
[ "$(count_of "$DEAD")" = none ] && [ "$(alerts)" = 1 ] && ok \
  || bad "S5 A's success (stderr on rc 0) resets it, no new line (count $(count_of "$DEAD"), $(alerts) lines)"
[[ "$(lastlog)" == *"pushed: $DEAD $B2"* ]] && [[ "$(lastlog)" != *FAILED:* ]] && ok || bad "S5 both pushed (got '$(lastlog)')"
run_snap SSH_OK="$B2IP" SSH_ERR="$ERRTXT"   # A 1
run_snap SSH_ERR="$ERRTXT"                  # A 2, B 1
[ "$(alerts_for "$DEAD")" = 1 ] && ok || bad "S5 A at 2 after the reset: no second line yet"
run_snap SSH_OK="$B2IP" SSH_ERR="$ERRTXT"   # A 3 -> second line; B ok
[ "$(alerts_for "$DEAD")" = 2 ] && [ "$(alerts_for "$B2")" = 0 ] && ok \
  || bad "S5 A's next streak alerts again, B never (got $(cat "$H/logs/ALERTS.log"))"

# ---------- S6: the knob -------------------------------------------------------
conf "$ROW_DEAD"; reset_state
run_snap VERCEL_PUSH_FAIL_STREAK=1 SSH_ERR="$ERRTXT"
[ "$(alerts)" = 1 ] && ok || bad "S6 VERCEL_PUSH_FAIL_STREAK=1 -> a line on run 1 (got $(alerts))"
for bogus in abc 0; do
  reset_state
  for n in 1 2 3; do
    run_snap VERCEL_PUSH_FAIL_STREAK="$bogus" SSH_ERR="$ERRTXT"
    want=0; [ "$n" -eq 3 ] && want=1
    [ "$(alerts)" = "$want" ] && ok || bad "S6 VERCEL_PUSH_FAIL_STREAK=$bogus reads as 3: run $n wants $want line(s) (got $(alerts))"
  done
done
reset_state
mkdir -p "$H/state/vercel-snapshot-push-fail"; echo x > "$H/state/vercel-snapshot-push-fail/$DEAD"
run_snap SSH_ERR="$ERRTXT"
[ "$(count_of "$DEAD")" = 1 ] && ok || bad "S6 a garbage count file restarts at 1 (got $(count_of "$DEAD"))"

# ---------- S7: the ssh error is cut to VERCEL_PUSH_ERR_CHARS ---------------
LONG="ssh-fixture-error-"$'\r'"$(printf 'x%.0s' $(seq 1 300))"
errpart() { grep '\[vercel-snapshot\] push to' "$H/logs/ALERTS.log" | head -1 | sed "s/.*host $DEADIP: //"; }
for spec in "-:200" "40:40" "x:200"; do
  k=${spec%%:*}; w=${spec#*:}
  reset_state
  if [ "$k" = - ]; then kv=(); else kv=(VERCEL_PUSH_ERR_CHARS="$k"); fi
  run_snap "${kv[@]}" VERCEL_PUSH_FAIL_STREAK=1 SSH_ERR="$LONG"
  E=$(errpart)
  [ "${#E}" -eq "$w" ] && [[ "$E" == ssh-fixture-error-x* ]] && [[ "$E" != *$'\r'* ]] && ok \
    || bad "S7 VERCEL_PUSH_ERR_CHARS=$k -> the error is $w chars with no CR (got ${#E}: '${E:0:60}...')"
done

# ---------- B: no real network -------------------------------------------------
! grep -qv '^https://api\.vercel\.com/' "$T/curl.log" && ok || bad "B curl saw only api.vercel.com fixture URLs ($(grep -v '^https://api\.vercel\.com/' "$T/curl.log" | head -3))"
[ -s "$T/curl.log" ] && ok || bad "B the curl stub answered the API reads"

echo "vercel-snapshot-push-host.bh-8545: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
