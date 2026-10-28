#!/bin/bash
# tests/pool-testhost-ensure.bh-8659-test.sh — the hub starts the test host
# before it ships a pool test-host route, and a live route holds the idle stop
# (BH-8659, follow-up of BH-8335).
#
# THE GAP. A pool machine reaches the test host with an app-scoped SSH token
# (BH-8335). That token cannot start a machine. When the idle stop had stopped
# the host, the pool gate recorded could-not-run.
#
# PINNED. Every case runs the REAL bin/testhost-tick.sh and/or the REAL
# bin/lib/pool-testhost-route.sh against its own scratch harness: a stub
# flyctl on PATH (every call logged with the credential it got), a file-backed
# settings stub, and mput/say/mexec function stubs. No network.
#   E1-E6 `ensure --route-until <epoch>`: the testhost.route_until row (max,
#         clamp, bad values), the `ensure-result:` line, rc; no flag = main's output.
#   H1-H6 `tick` and `idle`: a live route holds the stop; a past, absent or
#         bad row does not; an unreadable row is "do not stop" / `unknown`.
#   P1-P7 ptr_push / ptr_ensure_host: start before the MPUT, one say line,
#         the hub's own credential, the 3-key route file, fail-soft results,
#         the parse of the result line, and the real fly-pool.sh push block.
#   K1    the ensure timeout is the POOL_TESTHOST_ENSURE_TIMEOUT_S knob.
#   R1    round trip: lib -> tick writes the row -> tick/idle read it.
#   B1    every flyctl call lands in the stub.
#
# Run from anywhere: bash tests/pool-testhost-ensure.bh-8659-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR="$REPO"   # tests/lib/rendered.sh renders this repo's registry from $DIR
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$REPO/bin/testhost-tick.sh"
LIB="$REPO/bin/lib/pool-testhost-route.sh"
POOLSH="$REPO/bin/fly-pool.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REG=$(rendered_registry)
NOW=$(date -u '+%s')
MAXH=$(jq -r .max "$REPO/catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_TOKEN_HOURS.json")
APPTOK="FlyV1 fm2_fixture-apptoken-8659"

FB="$T/fakebin"; mkdir -p "$FB"
# flyctl: every call in $CALLS as `FLY <argv> cred=<access>|<api>`, plus one
# marker per call in $FIX/fly-marks (B1).
cat > "$FB/flyctl" <<STUB
#!/bin/bash
echo "FLY \$* cred=\${FLY_ACCESS_TOKEN:-}|\${FLY_API_TOKEN:-}" >> "\$CALLS"
echo x >> "\$FIX/fly-marks"
case "\$*" in
  "tokens create"*) echo "$APPTOK"; exit 0 ;;
  *"machine list"*|*"machines list"*) cat "\$FIX/machines.json"; exit 0 ;;
  *"machine status"*|*"machines status"*)
    printf 'Machine ID: 873eddb0433018\nState: %s\n\nVM\n CPU Kind │ performance\n vCPUs │ 16\n' "\$(cat "\$FIX/state")"; exit 0 ;;
  *"ssh console"*) echo "TESTHOST_BUSY \$(cat "\$FIX/busy" 2>/dev/null || echo 0)"; exit 0 ;;
  *"machine start"*) [ -f "\$FIX/start-fails" ] && exit 1; printf 'started\n' > "\$FIX/state"; exit 0 ;;
  *"machine stop"*)  printf 'stopped\n' > "\$FIX/state"; exit 0 ;;
esac
exit 0
STUB
# timeout: logs its first argument, then the real one.
cat > "$FB/timeout" <<'STUB'
#!/bin/bash
echo "TIMEOUT $1" >> "$CALLS"
exec /usr/bin/timeout "$@"
STUB
chmod +x "$FB"/*

# The tick's bin/lib closure, and the lib's, copied once (BH-4552); each case
# copies the tree it needs.
scratch_install_closure bin/testhost-tick.sh "$T/tpl-tick" >/dev/null || { echo "FAIL: cannot install the tick closure"; exit 1; }
scratch_install_closure bin/lib/pool-testhost-route.sh "$T/tpl-lib" >/dev/null || { echo "FAIL: cannot install the lib closure"; exit 1; }

# newcase — a fresh harness + fixture dir; sets C, FIX, H, CALLS.
N=0
newcase() {
  N=$((N+1)); C="$T/case-$N"; FIX="$C/fix"; H="$C/h"; CALLS="$FIX/calls"; LIBF=""
  mkdir -p "$FIX/settings" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state" "$H/env" "$C/home"
  cp -R "$T/tpl-tick/." "$H/"
  cp "$REG" "$H/catalog/lanes.json"
  cat > "$H/bin/jobs-client.sh" <<'STUB'
JOBS_BOX=fixture
flag_sync()  { return 1; }
setting_get() {
  [ -f "$FIX/d1-down" ] || [ -f "$FIX/down-$1" ] && return 1
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
setting_set() {
  [ -f "$FIX/d1-down" ] || [ -f "$FIX/down-$1" ] && return 1
  printf '%s' "$2" > "$FIX/settings/$1"
  printf '%s=%s\n' "$1" "$2" >> "$FIX/settings-writes"
  return 0
}
STUB
  printf '#!/bin/bash\necho "{\\"total\\":4,\\"online\\":4}"\nexit 0\n' > "$H/bin/ci-runners-status.sh"
  chmod +x "$H/bin/ci-runners-status.sh"
  printf 'FLY_API_TOKEN_TESTHOST=hub-testhost-fixture-token\n' > "$H/env/fly.env"
  printf '[{"id":"873eddb0433018","name":"testhost-1","state":"started"}]\n' > "$FIX/machines.json"
  printf 'started\n' > "$FIX/state"; printf '0\n' > "$FIX/busy"
  : > "$CALLS"
}
set_row() { printf '%s' "$2" > "$FIX/settings/$1"; }
row() { cat "$FIX/settings/$1" 2>/dev/null; }
BASEENV() { printf '%s\n' PATH="$FB:/usr/bin:/bin" HOME="$C/home" HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
  FIX="$FIX" CALLS="$CALLS" TESTHOST_APP=bh-testhost-fixture TESTHOST_IDLE_STOP_MIN=30; }
# tick <verb...> — the real tick in a clean env.
tick() {
  local -a e; mapfile -t e < <(BASEENV)
  OUT=$(env -i "${e[@]}" bash "$TICK" "$@" 2>&1); RC=$?
}
# lib <script> [env...] — the lib (default: the real one) in a clean env, with
# the pool's own token in FLY_ACCESS_TOKEN / FLY_API_TOKEN as on the pool tick.
lib() {
  local script=$1; shift; local -a e; mapfile -t e < <(BASEENV)
  LOUT=$(env -i "${e[@]}" FLY_ACCESS_TOKEN=pool-token-fixture FLY_API_TOKEN=pool-token-fixture "$@" \
    bash -c '. "$1"; say() { echo "SAY $*" >> "$CALLS"; }; mput() { echo "MPUT $1 $3" >> "$CALLS"; cp "$2" "$FIX/pushed"; }; mexec() { echo "MEXEC $*" >> "$CALLS"; }; '"$script" _ "${LIBF:-$LIB}" 2>&1); LRC=$?
}
flys()   { grep '^FLY ' "$CALLS"; }
fly_has() { grep -q "^FLY .*$1" "$CALLS"; }
say_has() { grep -qF -- "$1" <<<"$(says)"; }
says()   { grep '^SAY ' "$CALLS"; }
lastline() { printf '%s\n' "$OUT" | tail -n 1; }
newout() { local d; d=$(mktemp -d "$C/out-XXXXXX"); chmod 700 "$d"; echo "$d"; }
# route <outdir> <expires> — a route file as ptr_build writes it.
route() { ( umask 077; printf 'REMOTE_GATE_TRANSPORT=fly-ssh\nFLY_API_TOKEN=%s\nTESTHOST_ROUTE_EXPIRES=%s\n' "$APPTOK" "$2" > "$1/testhost.env" ); }
STARTED_RE='^SAY m-fixture: test host bh-testhost-fixture was stopped — started it before the route ship$'
NOTCONF_RE='^SAY m-fixture: test host ensure did not confirm a started host \(.*\) — the route ships, the selection gate may record could-not-run$'

# ── E: ensure --route-until ─────────────────────────────────────────────────
newcase; printf 'stopped\n' > "$FIX/state"
tick ensure --route-until "$((NOW + 3600))"
[ "$(row testhost.route_until)" = "$((NOW + 3600))" ] && ok || bad "E1: route_until not written: '$(row testhost.route_until)'"
fly_has 'machine start' && ok || bad "E1: no machine start: $(flys)"
[ "$(lastline)" = "ensure-result: started-now" ] && ok || bad "E1: last line '$(lastline)'"
[ "$RC" = 0 ] && ok || bad "E1: rc $RC"
# the hold is written BEFORE the start
WL=$(grep -n 'testhost.route_until=' "$FIX/settings-writes" | head -1 | cut -d: -f1)
[ "$WL" = 1 ] && ok || bad "E1: route_until is not the first write: $(cat "$FIX/settings-writes")"

newcase
tick ensure --route-until "$((NOW + 3600))"
fly_has 'machine start' && bad "E2: started a started host" || ok
[ "$(lastline)" = "ensure-result: was-started" ] && ok || bad "E2: last line '$(lastline)'"

newcase; set_row testhost.route_until "$((NOW + 7200))"
tick ensure --route-until "$((NOW + 3600))"
[ "$(row testhost.route_until)" = "$((NOW + 7200))" ] && ok || bad "E3: max not kept: '$(row testhost.route_until)'"
newcase; set_row testhost.route_until "$((NOW + 60))"
tick ensure --route-until "$((NOW + 3600))"
[ "$(row testhost.route_until)" = "$((NOW + 3600))" ] && ok || bad "E3: a later route did not raise the row: '$(row testhost.route_until)'"

newcase
tick ensure --route-until "$((NOW + 10 * 365 * 86400))"
V=$(row testhost.route_until)
[ -n "$V" ] && [ "$V" -le "$((NOW + MAXH * 3600 + 60))" ] && [ "$V" -ge "$((NOW + MAXH * 3600 - 60))" ] && ok \
  || bad "E4: 10 years not clamped to ${MAXH}h: '$V'"
newcase
tick ensure --route-until 99999999999999999999999999
V=$(row testhost.route_until)
[ -n "$V" ] && [ "$V" -le "$((NOW + MAXH * 3600 + 60))" ] && [ "$V" -gt "$NOW" ] && ok || bad "E4: an overflow value not clamped: '$V'"
for v in abc "$((NOW - 5))" "" -5; do
  newcase; printf 'stopped\n' > "$FIX/state"
  tick ensure --route-until "$v"
  [ -z "$(row testhost.route_until)" ] && ok || bad "E4 '$v': a row was written: '$(row testhost.route_until)'"
  [ "$(grep -c 'is not a future epoch — no route hold written' <<<"$OUT")" = 1 ] && ok || bad "E4 '$v': want one say line: $OUT"
  fly_has 'machine start' && ok || bad "E4 '$v': the ensure did not run"
  [ "$(lastline)" = "ensure-result: started-now" ] && ok || bad "E4 '$v': last line '$(lastline)'"
done
newcase; : > "$FIX/down-testhost.route_until"
tick ensure --route-until "$((NOW + 3600))"
grep -q 'the worker did not take testhost.route_until — the idle stop cannot see this route' <<<"$OUT" && ok || bad "E4: a refused write was not said: $OUT"
[ "$(lastline)" = "ensure-result: was-started" ] && ok || bad "E4: a refused write stopped the ensure: $(lastline)"

newcase; printf 'stopped\n' > "$FIX/state"
tick ensure
grep -q 'ensure-result' <<<"$OUT" && bad "E5: no flag but a result line: $OUT" || ok
[ -z "$(row testhost.route_until)" ] && ok || bad "E5: no flag but a route_until row"
[ "$OUT" = "testhost-tick: starting bh-testhost-fixture (state was stopped)" ] && ok || bad "E5: no-flag output changed: '$OUT'"

newcase; printf 'stopped\n' > "$FIX/state"; : > "$FIX/start-fails"
tick ensure --route-until "$((NOW + 3600))"
[ "$(lastline)" = "ensure-result: start-failed" ] && ok || bad "E6: last line '$(lastline)'"
[ "$RC" = 1 ] && ok || bad "E6: rc $RC, want 1"
newcase; printf 'stopped\n' > "$FIX/state"; : > "$FIX/start-fails"
tick ensure
[ "$RC" = 1 ] && ok || bad "E6: no flag: rc $RC, want 1"
newcase; printf 'weird\n' > "$FIX/state"; printf 'garbage\n' > "$FIX/machines.json"
tick ensure --route-until "$((NOW + 3600))"
# a machine list that does not parse is state `unknown`: no start, rc 0
grep -q 'not starting anything blind' <<<"$OUT" && ok || bad "E6: the fixture did not reach the unknown state: $OUT"
[ "$(lastline)" = "ensure-result: unknown" ] && [ "$RC" = 0 ] && ok || bad "E6: unknown state: last line '$(lastline)' rc $RC"
fly_has 'machine start' && bad "E6: started an unknown host" || ok

# ── H: the idle stop and a live route ───────────────────────────────────────
hcase() { newcase; set_row testhost.last_used "$((NOW - 7200))"; }
hcase; set_row testhost.route_until "$((NOW + 3600))"
tick
fly_has 'machine stop' && bad "H1: stopped with a live route: $OUT" || ok
grep -q 'a pool test-host route is live until' "$H/logs/testhost-tick.log" && ok || bad "H1: no hold log line"
[ "$RC" = 0 ] && ok || bad "H1: rc $RC"
hcase; set_row testhost.route_until "$((NOW + 3600))"; printf '1\n' > "$FIX/busy"
tick idle 873eddb0433018
[ "$OUT" = 0 ] && [ "$RC" = 0 ] && ok || bad "H2: idle with a live route: '$OUT' rc $RC"
fly_has 'ssh console' && bad "H2: probed the host with a live route" || ok
hcase; set_row testhost.route_until "$((NOW - 60))"
tick
fly_has 'machine stop' && ok || bad "H3: a past route held the stop: $OUT"
tick idle 873eddb0433018
[ "$OUT" -ge 7200 ] 2>/dev/null && ok || bad "H3: idle with a past route: '$OUT'"
hcase
tick
fly_has 'machine stop' && ok || bad "H4: no route row held the stop: $OUT"
for v in abc "" -5 "$NOW"; do
  hcase; set_row testhost.route_until "$v"
  tick
  fly_has 'machine stop' && ok || bad "H5 '$v': a bad or ended row held the stop: $OUT"
done
hcase; set_row testhost.route_until "$((NOW + 3600))"; : > "$FIX/down-testhost.route_until"
tick
fly_has 'machine stop' && bad "H6: stopped on an unreadable route row" || ok
grep -q 'could not read testhost.route_until — NOT stopping' <<<"$OUT" && ok || bad "H6: no say line: $OUT"
tick idle 873eddb0433018
[ "$OUT" = unknown ] && [ "$RC" = 2 ] && ok || bad "H6: idle: '$OUT' rc $RC"
# inside the use window the route row is not even needed
hcase; set_row testhost.last_used "$NOW"; set_row testhost.route_until "$((NOW - 60))"
tick
fly_has 'machine stop' && bad "H: stopped inside the use window" || ok

# ── P: ptr_push and ptr_ensure_host (real lib, real tick) ───────────────────
newcase; printf 'stopped\n' > "$FIX/state"; O=$(newout)
lib "ptr_build '$O' BH-8659 && ptr_push m-fixture '$O'" POOL_TESTHOST_ROUTE=1
[ "$LRC" = 0 ] && ok || bad "P1: rc $LRC: $LOUT"
SL=$(grep -n '^FLY machine start' "$CALLS" | head -1 | cut -d: -f1)
ML=$(grep -n '^MPUT' "$CALLS" | head -1 | cut -d: -f1)
[ -n "$SL" ] && [ -n "$ML" ] && [ "$SL" -lt "$ML" ] && ok || bad "P1: start ($SL) not before MPUT ($ML): $(cat "$CALLS")"
[ "$(says | wc -l)" = 1 ] && grep -qE "$STARTED_RE" "$CALLS" && ok || bad "P1: want one started line: $(says)"
EXP=$(sed -n 's/^TESTHOST_ROUTE_EXPIRES=//p' "$O/testhost.env")
[ -n "$EXP" ] && [ "$(row testhost.route_until)" = "$EXP" ] && ok || bad "P1/R1: route_until '$(row testhost.route_until)' != expiry '$EXP'"
# P2: the hub's credential, never the pool's
grep -q '^FLY machine.*pool-token-fixture' "$CALLS" && bad "P2: the ensure ran with the pool token: $(flys)" || ok
grep -q '^FLY machine start.*cred=hub-testhost-fixture-token|hub-testhost-fixture-token' "$CALLS" && ok || bad "P2: the start did not use env/fly.env's FLY_API_TOKEN_TESTHOST: $(flys)"
# P4: one file pushed, 3 keys, the app-scoped token; nothing through mexec
[ "$(grep '^MPUT' "$CALLS")" = "MPUT m-fixture /run/harness-env/testhost.env" ] && ok || bad "P4: pushes: $(grep MPUT "$CALLS")"
[ "$(cut -d= -f1 "$FIX/pushed" | tr '\n' ' ')" = "REMOTE_GATE_TRANSPORT FLY_API_TOKEN TESTHOST_ROUTE_EXPIRES " ] && ok || bad "P4: keys: $(cut -d= -f1 "$FIX/pushed")"
grep -qx "FLY_API_TOKEN=$APPTOK" "$FIX/pushed" && ok || bad "P4: the pushed token is not the app-scoped one"
grep -q 'hub-testhost-fixture-token' "$FIX/pushed" && bad "P4: the hub credential left the hub" || ok
grep -q '^MEXEC' "$CALLS" && bad "P4: the ensure went through mexec" || ok
# R1: the hold the lib wrote stops the next idle tick and answers `idle`
set_row testhost.last_used "$((NOW - 7200))"; : > "$CALLS"
tick
fly_has 'machine stop' && bad "R1: the tick stopped the host under a shipped route: $OUT" || ok
tick idle 873eddb0433018
[ "$OUT" = 0 ] && ok || bad "R1: idle under a shipped route: '$OUT'"

newcase; O=$(newout); route "$O" "$((NOW + 21600))"
lib "ptr_push m-fixture '$O'"
fly_has 'machine start' && bad "P3: started a started host" || ok
[ -z "$(says)" ] && ok || bad "P3: a started host said something: $(says)"
[ "$(grep -c '^MPUT' "$CALLS")" = 1 ] && ok || bad "P3: want one MPUT"
[ "$LRC" = 0 ] && ok || bad "P3: rc $LRC"

newcase; printf 'stopped\n' > "$FIX/state"; : > "$FIX/start-fails"; O=$(newout); route "$O" "$((NOW + 21600))"
lib "ptr_push m-fixture '$O'"
[ "$LRC" = 0 ] && ok || bad "P5 start-failed: rc $LRC"
[ "$(says | wc -l)" = 1 ] && grep -qE "$NOTCONF_RE" "$CALLS" && say_has '(start-failed)' && ok || bad "P5 start-failed: $(says)"
[ "$(grep -c '^MPUT' "$CALLS")" = 1 ] && ok || bad "P5 start-failed: the route did not ship"
[ ! -e "$H/logs/ALERTS.log" ] && ok || bad "P5: ALERTS written"

# P5/P6/K1: a fake tick beside a copy of the lib. It logs its argv and the
# credential it got, then prints $FIX/tick-out and exits $FIX/tick-rc.
fakelib() {
  mkdir -p "$C/fake"; cp -R "$T/tpl-lib/." "$C/fake/"
  LIBF="$C/fake/bin/lib/pool-testhost-route.sh"
  cat > "$C/fake/bin/testhost-tick.sh" <<'STUB'
echo "TICK $* cred=${FLY_ACCESS_TOKEN:-}|${FLY_API_TOKEN:-}" >> "$CALLS"
[ -f "$FIX/tick-sleep" ] && sleep 5   # determinism: ok race-sleep the stub simulates a hung tick; the 1 s timeout kills it
cat "$FIX/tick-out" 2>/dev/null
exit "$(cat "$FIX/tick-rc" 2>/dev/null || echo 0)"
STUB
}
pcase() { # pcase <tick output> <want: none|started|notconf> <label> [rc]
  newcase; fakelib; O=$(newout); route "$O" "$((NOW + 21600))"
  printf '%b' "$1" > "$FIX/tick-out"; [ -n "${4:-}" ] && printf '%s' "$4" > "$FIX/tick-rc"
  lib "ptr_push m-fixture '$O'"
  [ "$LRC" = 0 ] && [ "$(grep -c '^MPUT' "$CALLS")" = 1 ] && ok || bad "P6 $3: rc $LRC or no MPUT"
  case "$2" in
    none)    [ -z "$(says)" ] && ok || bad "P6 $3: want no say line: $(says)" ;;
    started) [ "$(says | wc -l)" = 1 ] && grep -qE "$STARTED_RE" "$CALLS" && ok || bad "P6 $3: want the started line: $(says)" ;;
    notconf) [ "$(says | wc -l)" = 1 ] && grep -qE "$NOTCONF_RE" "$CALLS" && ok || bad "P6 $3: want the not-confirmed line: $(says)" ;;
  esac
}
pcase 'testhost-tick: x\nensure-result: was-started\n' none was-started
grep -q "^TICK ensure --route-until $((NOW + 21600)) cred=|$" "$CALLS" && ok || bad "P2/P6: the tick argv or credential: $(grep TICK "$CALLS")"
pcase 'testhost-tick: starting\nensure-result: started-now\n' started started-now
pcase 'ensure-result: unknown\n' notconf unknown
pcase 'ensure-result: start-failed\n' notconf start-failed 1
say_has '(start-failed)' && ok || bad "P6: the result word is not in the line: $(says)"
pcase 'testhost-tick: starting bh-testhost-fixture (state was stopped)\n' notconf "no result line"
say_has '(rc 0)' && ok || bad "P6: no result: want '(rc 0)': $(says)"
pcase 'ensure-result: started-nowx\n' notconf started-nowx
pcase 'ensure-result:\n' notconf "empty result"
pcase 'ensure-result: \n' notconf "blank result"
pcase 'ensure-result: started-now\nensure-result: start-failed\n' notconf "last wins (failed)"
pcase 'ensure-result: start-failed\nensure-result: started-now\n' started "last wins (started)"
pcase 'testhost-tick: started it\nensure-result: start-failed\n' notconf "a say line with started"
pcase '  ensure-result: started-now\n' notconf "indented"
# timeout: the knob at 1 s, the tick sleeps 5
newcase; fakelib; O=$(newout); route "$O" "$((NOW + 21600))"; : > "$FIX/tick-sleep"
lib "ptr_push m-fixture '$O'" POOL_TESTHOST_ENSURE_TIMEOUT_S=1
grep -qE "$NOTCONF_RE" "$CALLS" && say_has '(rc 124)' && ok || bad "P5 timeout: $(says)"
[ "$(grep -c '^MPUT' "$CALLS")" = 1 ] && [ "$LRC" = 0 ] && ok || bad "P5 timeout: the route did not ship"
# missing tick script
newcase; fakelib; rm -f "$C/fake/bin/testhost-tick.sh"; O=$(newout); route "$O" "$((NOW + 21600))"
lib "ptr_push m-fixture '$O'"
[ "$(says | wc -l)" = 1 ] && grep -qE "$NOTCONF_RE" "$CALLS" && [ "$(grep -c '^MPUT' "$CALLS")" = 1 ] && ok || bad "P5 missing tick: $(cat "$CALLS")"
# a route file with no expiry: the ensure runs with no flag, the route ships
newcase; fakelib; O=$(newout); printf 'REMOTE_GATE_TRANSPORT=fly-ssh\n' > "$O/testhost.env"
printf 'ensure-result: was-started\n' > "$FIX/tick-out"
lib "ptr_push m-fixture '$O'"
grep -qx 'TICK ensure cred=|' "$CALLS" && ok || bad "P5 no expiry: tick argv: $(grep TICK "$CALLS")"

# K1: the knob through lane_knob, and the 120 s fallback with no knob
newcase; fakelib; O=$(newout); route "$O" "$((NOW + 21600))"; printf 'ensure-result: was-started\n' > "$FIX/tick-out"
lib "lane_knob() { case \"\$2\" in POOL_TESTHOST_ENSURE_TIMEOUT_S) echo 15 ;; esac; }; ptr_push m-fixture '$O'"
grep -qx 'TIMEOUT 15' "$CALLS" && ok || bad "K1: the knob did not bound the ensure: $(grep TIMEOUT "$CALLS")"
lib "ptr_push m-fixture '$O'"
grep -qx 'TIMEOUT 120' "$CALLS" && ok || bad "K1: no knob: want the 120 fallback: $(grep TIMEOUT "$CALLS")"
[ "$(jq -r .default "$REPO/catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_ENSURE_TIMEOUT_S.json" 2>/dev/null)" = 120 ] && ok \
  || bad "K1: the registry default of POOL_TESTHOST_ENSURE_TIMEOUT_S is not 120"

# P7: the real fly-pool.sh push block, a stopped host: started, then shipped.
PUSHB=$(sed -n '/^ *# >>> pool testhost route push$/,/^ *# <<< pool testhost route push$/p' "$POOLSH")
[ -n "$PUSHB" ] && ok || bad "P7: no push block in bin/fly-pool.sh"
newcase; printf 'stopped\n' > "$FIX/state"; O=$(newout); route "$O" "$((NOW + 21600))"
printf '%s\n' "$PUSHB" > "$C/push-block.sh"
lib "MID=m-fixture; KEY=BH-8659; TMP='$O'; . '$C/push-block.sh'"
SEQ=$(grep -E '^(FLY machine start|MPUT|SAY)' "$CALLS" | sed 's/ cred=.*//; s/(expires .*)/(expires X)/' | tr '\n' '|')
[ "$SEQ" = "FLY machine start 873eddb0433018 -a bh-testhost-fixture|SAY m-fixture: test host bh-testhost-fixture was stopped — started it before the route ship|MPUT m-fixture /run/harness-env/testhost.env|SAY BH-8659: testhost route shipped to m-fixture (expires X)|" ] && ok \
  || bad "P7: push block sequence: $SEQ"

# ── B1: 0 real Fly calls ────────────────────────────────────────────────────
FBIN=$(env -i PATH="$FB:/usr/bin:/bin" HOME="$C/home" bash -c '. "$1"; fly_bin' _ "$REPO/bin/lib/fly-bin.sh")
[ "$FBIN" = "$FB/flyctl" ] && ok || bad "B1: fly_bin resolves to '$FBIN', not the stub"
MARKS=$(cat "$T"/case-*/fix/fly-marks 2>/dev/null | wc -l)
LOGGED=$(cat "$T"/case-*/fix/calls 2>/dev/null | grep -c '^FLY ')
[ "$MARKS" -gt 0 ] && ok || bad "B1: the stub was never called (the suite tests nothing)"
[ "$MARKS" -ge "$LOGGED" ] && ok || bad "B1: marks $MARKS < logged $LOGGED"

echo "pool-testhost-ensure.bh-8659: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
