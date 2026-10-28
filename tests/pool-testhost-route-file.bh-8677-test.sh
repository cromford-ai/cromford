#!/bin/bash
# tests/pool-testhost-route-file.bh-8677-test.sh — the pool's test-host route
# ships a pre-minted, app-scoped token file before it tries a mint (BH-8677).
#
# THE BUG. The hub's FLY_API_TOKEN is deploy-scoped, so `flyctl tokens create
# ssh` answers `Not authorized`. ptr_build had no credential source but the
# mint, so every pool spawn shipped no route, and the reason line said only
# `token mint rc 1`, which hid the cause.
#
# PINNED. bin/lib/pool-testhost-route.sh in a clean shell; flyctl is a PATH
# stub (no network); bin/alert-line.sh is copied into a scratch harness with
# no bin/beat.sh, so the alert only appends to logs/ALERTS.log.
#   F1  a mode-600 file, expiry NOW+100h: rc 0, the file's token and expiry
#       ship, mode 600, flyctl never called, the token on no output.
#   F2  mode 644 / F2b mode 640 / F2c a symlink to a 600 file: falls through.
#   F3  expiry NOW+2h / F3b exactly NOW+6h (h=6): falls through.
#   F4  expiry in the past: falls through, not shipped.
#   F5  a token with no FlyV1 prefix / F5b a non-digit expiry: falls through.
#   F6  no file, the mint succeeds: today's behaviour.
#   F7  two TESTHOST_ROUTE_TOKEN lines: the last one ships.
#   F8  POOL_TESTHOST_ROUTE=0 with a valid file: rc 3, nothing written or run.
#   F9  testhost.env from the file has exactly the three remote-gate keys.
#   C1  no file, `Not authorized`: the cause-class reason line, no cause file left.
#   C2  `no access token available` / C3 no text: `token mint rc 1`.
#   C4  rc 0 and no FlyV1 word: `token empty`.
#   A1  expiry NOW+30h: ships AND writes one ALERTS line with the mint command.
#   A2  a second call the same UTC day: still one line.
#   A3  an expired file: one line, no ship.
#   A4  two concurrent ptr_build calls on one harness: one line.
#   A5  the warn knob at 10 h, expiry NOW+30h: no line.
#   A6  a marker from another day is deleted when today's marker is made.
#
# Run from anywhere: bash tests/pool-testhost-route-file.bh-8677-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/bin/lib/pool-testhost-route.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$LIB" ] || { echo "FAIL: bin/lib/pool-testhost-route.sh does not exist"; exit 1; }

NOW=$(date +%s)
FTOK="FlyV1 fixturetok"
UNAUTH='Error: failed creating token: input:3:2: createLimitedAccessToken Not authorized to access this createlimitedaccesstoken'
CAUSE_LINE='testhost route: not shipped (hub token cannot mint tokens; put a pre-minted token in env/testhost-route.env)'
ALERT_RE='^[0-9-]+ [0-9:]+Z \[cromford\] testhost route token expires [0-9T:-]+Z; mint a new one: flyctl tokens create ssh -a bh-testhost-example-org -x 720h -n hub-testhost-route$'

FB="$T/fakebin"; mkdir -p "$FB"
# flyctl: every call appends argv to $CALLS. MINT=unauth (default) | noaccess
# | silent | ok | notoken.
cat > "$FB/flyctl" <<STUB
#!/bin/bash
echo "\$*" >> "\$CALLS"
case "\${MINT:-unauth}" in
  unauth) echo "$UNAUTH"; exit 1 ;;
  noaccess) echo "Error: no access token available"; exit 1 ;;
  silent) exit 1 ;;
  ok) echo "FlyV1 minted"; exit 0 ;;
  notoken) echo "Created token"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$FB/flyctl"

# newh — a fresh harness root per case: its own env dir, state and ALERTS.log.
newh() {
  local h; h=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$h/bin" "$h/env" "$h/logs" "$h/state"
  cp "$REPO/bin/alert-line.sh" "$h/bin/"; chmod +x "$h/bin/alert-line.sh"
  echo "$h"
}
newout() { local d; d=$(mktemp -d "$T/out-XXXXXX"); chmod 700 "$d"; echo "$d"; }
# putfile <h> <token> <expiry> [mode] — the pre-minted file.
putfile() {
  printf 'TESTHOST_ROUTE_TOKEN=%s\nTESTHOST_ROUTE_EXPIRES=%s\n' "$2" "$3" > "$1/env/testhost-route.env"
  chmod "${4:-600}" "$1/env/testhost-route.env"
}
alerts() { grep -c . "$1/logs/ALERTS.log" 2>/dev/null || echo 0; }

# run <h> <out> [env...] — ptr_build in a clean shell. Sets LRC, LERR, LOUT, CALLN.
run() {
  local h=$1 o=$2; shift 2
  : > "$h/calls"
  LOUT=$(cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T" HARNESS="$h" HARNESS_ENV_DIR="$h/env" JOBS_URL= \
    CALLS="$h/calls" FLY="$FB/flyctl" PTR_NOW="$NOW" POOL_TESTHOST_ROUTE=1 POOL_TESTHOST_TOKEN_HOURS=6 "$@" \
    bash -c '. "$1"; ptr_build "$2" BH-8677' _ "$LIB" "$o" 2>"$h/lerr"); LRC=$?
  LERR=$(cat "$h/lerr")
  CALLN=$(grep -c . "$h/calls" 2>/dev/null)
}
# fallthrough <case> — rc 1, no testhost.env, flyctl was called, the cause line.
fallthrough() {
  [ "$LRC" = 1 ] && ok || bad "$1: rc $LRC, want 1 (fall through to the mint): $LERR"
  [ -e "$O/testhost.env" ] && bad "$1: a testhost.env was written" || ok
  [ "$CALLN" -ge 1 ] && ok || bad "$1: flyctl was not called (no fall-through)"
  [ "$LERR" = "$CAUSE_LINE" ] && ok || bad "$1: stderr '$LERR', want the cause-class line"
}

# ── F1 ──────────────────────────────────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 360000))
run "$H" "$O"
[ "$LRC" = 0 ] && ok || bad "F1: rc $LRC, want 0: $LERR"
grep -qx "FLY_API_TOKEN=$FTOK" "$O/testhost.env" 2>/dev/null && ok || bad "F1: the file's token is not in testhost.env"
grep -qx "TESTHOST_ROUTE_EXPIRES=$((NOW + 21600))" "$O/testhost.env" 2>/dev/null && ok || bad "F1: the shipped expiry is not NOW+6h (the file expiry must not drive the route hold)"
[ "$(stat -c %a "$O/testhost.env" 2>/dev/null)" = 600 ] && ok || bad "F1: testhost.env mode is not 600"
[ "$CALLN" = 0 ] && ok || bad "F1: flyctl was called $CALLN time(s): $(cat "$H/calls")"
grep -q fixturetok <<<"$LOUT$LERR" && bad "F1: the token reached stdout/stderr" || ok
[ "$(alerts "$H")" = 0 ] && ok || bad "F1: an alert was written for a 100 h expiry"
grep -rq fixturetok "$H/logs" "$H/state" 2>/dev/null && bad "F1: the token reached a log or state file" || ok
# F9: the remote-gate whitelist keys, exactly.
KEYS=$(sed 's/=.*//' "$O/testhost.env" 2>/dev/null | tr '\n' ' ')
[ "$KEYS" = "REMOTE_GATE_TRANSPORT FLY_API_TOKEN TESTHOST_ROUTE_EXPIRES " ] && ok || bad "F9: testhost.env keys '$KEYS'"
grep -qx 'REMOTE_GATE_TRANSPORT=fly-ssh' "$O/testhost.env" 2>/dev/null && ok || bad "F9: the transport is not fly-ssh"
# ptr_expires shows the shipped expiry (the build's window, not the file's).
PE=$(bash -c '. "$1"; ptr_expires "$2"' _ "$LIB" "$O")
[ "$PE" = "$(date -u -d "@$((NOW + 21600))" '+%Y-%m-%dT%H:%MZ')" ] && ok || bad "F1: ptr_expires '$PE'"

# ── F2 / F2b / F2c: mode and symlink ────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 360000)) 644
run "$H" "$O"; fallthrough F2
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 360000)) 640
run "$H" "$O"; fallthrough F2b
H=$(newh); O=$(newout); mkdir -p "$H/real"
printf 'TESTHOST_ROUTE_TOKEN=%s\nTESTHOST_ROUTE_EXPIRES=%s\n' "$FTOK" $((NOW + 360000)) > "$H/real/r.env"; chmod 600 "$H/real/r.env"
ln -s "$H/real/r.env" "$H/env/testhost-route.env"
run "$H" "$O"; fallthrough F2c

# ── F3 / F3b: expiry inside ptr_hours ───────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 7200))
run "$H" "$O"; fallthrough F3
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 21600))
run "$H" "$O"; fallthrough F3b

# ── F4: expired ─────────────────────────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW - 60))
run "$H" "$O"; fallthrough F4

# ── F5 / F5b: bad format ────────────────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" abc $((NOW + 360000))
run "$H" "$O"; fallthrough F5
H=$(newh); O=$(newout); putfile "$H" "$FTOK" 17x
run "$H" "$O"; fallthrough F5b

# ── F6: no file, the mint works ─────────────────────────────────────────────
H=$(newh); O=$(newout)
run "$H" "$O" MINT=ok
[ "$LRC" = 0 ] && ok || bad "F6: rc $LRC: $LERR"
grep -qx 'FLY_API_TOKEN=FlyV1 minted' "$O/testhost.env" 2>/dev/null && ok || bad "F6: the minted token is not in testhost.env"
grep -qx "TESTHOST_ROUTE_EXPIRES=$((NOW + 21600))" "$O/testhost.env" 2>/dev/null && ok || bad "F6: the expiry is not NOW+6h"
[ "$CALLN" = 1 ] && ok || bad "F6: want one mint call, got $CALLN"

# ── F7: the last key line wins ──────────────────────────────────────────────
H=$(newh); O=$(newout)
printf 'TESTHOST_ROUTE_TOKEN=FlyV1 firsttok\nTESTHOST_ROUTE_TOKEN=FlyV1 lasttok\nTESTHOST_ROUTE_EXPIRES=%s\n' $((NOW + 360000)) > "$H/env/testhost-route.env"
chmod 600 "$H/env/testhost-route.env"
run "$H" "$O"
[ "$LRC" = 0 ] && grep -qx 'FLY_API_TOKEN=FlyV1 lasttok' "$O/testhost.env" 2>/dev/null && ok || bad "F7: rc $LRC, the last token line did not ship"

# ── F8: the knob off ────────────────────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 360000))
run "$H" "$O" POOL_TESTHOST_ROUTE=0
[ "$LRC" = 3 ] && ok || bad "F8: rc $LRC, want 3"
[ -e "$O/testhost.env" ] && bad "F8: testhost.env written with the knob off" || ok
[ "$CALLN" = 0 ] && ok || bad "F8: flyctl called with the knob off"

# ── C1-C4: the cause class ──────────────────────────────────────────────────
H=$(newh); O=$(newout)
run "$H" "$O"
[ "$LRC" = 1 ] && ok || bad "C1: rc $LRC"
[ "$LERR" = "$CAUSE_LINE" ] && ok || bad "C1: stderr '$LERR'"
[ "$CALLN" = 2 ] && ok || bad "C1: want two mint tries (env, session), got $CALLN"
[ "$(ls -A "$O")" = "" ] && ok || bad "C1: the outdir is not empty: $(ls -A "$O" | tr '\n' ' ')"
H=$(newh); O=$(newout)
run "$H" "$O" MINT=noaccess
[ "$LERR" = 'testhost route: not shipped (token mint rc 1)' ] && ok || bad "C2: stderr '$LERR'"
[ "$(ls -A "$O")" = "" ] && ok || bad "C2: the outdir is not empty"
H=$(newh); O=$(newout)
run "$H" "$O" MINT=silent
[ "$LERR" = 'testhost route: not shipped (token mint rc 1)' ] && ok || bad "C3: stderr '$LERR'"
H=$(newh); O=$(newout)
run "$H" "$O" MINT=notoken
[ "$LERR" = 'testhost route: not shipped (token empty)' ] && ok || bad "C4: stderr '$LERR'"

# ── A1 / A2: the expiry alert, once per UTC day ─────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 108000))
run "$H" "$O"
[ "$LRC" = 0 ] && grep -qx "FLY_API_TOKEN=$FTOK" "$O/testhost.env" 2>/dev/null && ok || bad "A1: a 30 h file did not ship: rc $LRC $LERR"
[ "$(alerts "$H")" = 1 ] && ok || bad "A1: want 1 ALERTS line, got $(alerts "$H")"
grep -qE "$ALERT_RE" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "A1: the ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "expires $(date -u -d "@$((NOW + 108000))" '+%Y-%m-%dT%H:%MZ');" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "A1: the line does not name the file's expiry"
grep -q fixturetok "$H/logs/ALERTS.log" 2>/dev/null && bad "A1: the token is in ALERTS.log" || ok
O=$(newout); run "$H" "$O"
[ "$(alerts "$H")" = 1 ] && ok || bad "A2: a second call the same day: want 1 ALERTS line, got $(alerts "$H")"

# ── A3: expired file: one line, no ship ─────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW - 60))
run "$H" "$O"
[ "$LRC" = 1 ] && [ ! -e "$O/testhost.env" ] && ok || bad "A3: an expired file shipped: rc $LRC"
[ "$(alerts "$H")" = 1 ] && ok || bad "A3: want 1 ALERTS line, got $(alerts "$H")"

# ── A4: two concurrent calls, one line ──────────────────────────────────────
H=$(newh); putfile "$H" "$FTOK" $((NOW + 108000))
O1=$(newout); O2=$(newout)
for o in "$O1" "$O2"; do
  ( cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" JOBS_URL= \
      CALLS="$H/calls" FLY="$FB/flyctl" PTR_NOW="$NOW" POOL_TESTHOST_ROUTE=1 POOL_TESTHOST_TOKEN_HOURS=6 \
      bash -c '. "$1"; ptr_build "$2" BH-8677' _ "$LIB" "$o" 2>/dev/null ) &
done
wait
[ "$(alerts "$H")" = 1 ] && ok || bad "A4: two concurrent calls: want 1 ALERTS line, got $(alerts "$H")"
[ -s "$O1/testhost.env" ] && [ -s "$O2/testhost.env" ] && ok || bad "A4: both calls must ship"

# ── A5: the warn knob ───────────────────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 108000))
run "$H" "$O" POOL_TESTHOST_ROUTE_WARN_HOURS=10
[ "$LRC" = 0 ] && ok || bad "A5: rc $LRC"
[ "$(alerts "$H")" = 0 ] && ok || bad "A5: knob 10 h, expiry 30 h: want 0 ALERTS lines, got $(alerts "$H")"

# ── A6: a stale marker is deleted ───────────────────────────────────────────
H=$(newh); O=$(newout); putfile "$H" "$FTOK" $((NOW + 108000))
mkdir -p "$H/state/testhost-route"; : > "$H/state/testhost-route/alerted-testhost-route-token-20000101"
run "$H" "$O"
[ -e "$H/state/testhost-route/alerted-testhost-route-token-20000101" ] && bad "A6: the stale marker was kept" || ok
[ -e "$H/state/testhost-route/alerted-testhost-route-token-$(date -u -d "@$NOW" +%Y%m%d)" ] && ok || bad "A6: today's marker is missing"
[ "$(alerts "$H")" = 1 ] && ok || bad "A6: want 1 ALERTS line, got $(alerts "$H")"

echo "pool-testhost-route-file.bh-8677: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
