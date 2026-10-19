#!/bin/bash
# tests/fly-pool-tick-stop.bh-7475-test.sh — a pool tick stops at a row boundary
# when its code changed or it ran past POOL_TICK_MAX_AGE_S, and frees the lock (BH-7475).
#
#   A  the lib is replaced by rename during row 1: 1 spawn, one "code changed"
#      line, rc 0, the other rows stay queued, the lock is free
#   B  near miss: an unnamed file is replaced: every row is decided, no stop
#   C  POOL_TICK_MAX_AGE_S=8, 10 s PR reads: 1 row, one stop line, ONE ALERTS line
#   D  POOL_TICK_MAX_AGE_S=0 (off): no stop
#   E  knob unset (default 1200): no stop
#   F  control: an outside flock holds the lock, the tick exits "already running"
#   R  the code changes during the REAP walk: machine 2 is not visited, its file
#      stays, the spawn walk is not entered, the lock is free
#   U1-U6  pts_stop_due on its own, on a fixed clock (PTS_NOW)
# determinism: ok-file the sleeps are the stub gh's deliberate PR-read delay (the
# max age under test), never synchronisation; the clock reads only time the tick.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# POOL_SCRIPT: the script under test (the plan's red run points it at origin/main).
POOL_SCRIPT="${POOL_SCRIPT:-$DIR/bin/fly-pool.sh}"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/lib/pool-tick-stop.sh "$H" >/dev/null || { echo "closure install of bin/lib/pool-tick-stop.sh failed"; exit 1; }
: > "$H/bin/unrelated.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
scratch_install_closure bin/lib/flags.sh "$H" >/dev/null || { echo "closure install of bin/lib/flags.sh failed"; exit 1; }
scratch_install_closure bin/lib/hold.sh "$H" >/dev/null || { echo "closure install of bin/lib/hold.sh failed"; exit 1; }
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; [ "${KEEP_ALERTS:-0}" = 1 ] || : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$POOL_SCRIPT" project-5 >/dev/null 2>&1 ); RC=$?
}

write_fly_stub() {
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
# SWAP=<path> SWAP_ON=<glob> replaces <path> by cp+mv (a new inode, as rsync does)
# on the first call whose args match <glob>.
if [ -n "\${SWAP:-}" ] && [[ "\$*" == \${SWAP_ON:-} ]] && [ ! -e "$T/swapped" ]; then
  : > "$T/swapped"; cp "\$SWAP" "\$SWAP.new" && mv -f "\$SWAP.new" "\$SWAP"
fi
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) cat "$T/listing.json" 2>/dev/null || echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

# gh stub. The repo probe answers 200 and the hold reads say "open, ai-build", so
# the gates apply and pass. The PR read (pulls?state=open&head=) is the variable:
#   PRMODE=none  exit 1, no output (the unreadable shape under load)
#   PRMODE=hang  exec sleep 30 (a read that never returns)
#   PRMODE=slow  sleep 2, then 200 []
#   PRMODE=ok    200 []
# Every PR read is appended to $T/pr-reads.
write_gh_stub() {
  cat > "$T/fakebin/gh" <<GH
#!/bin/bash
# SWAP=<path> SWAP_ON=<glob> replaces <path> by cp+mv (a new inode, as rsync does)
# on the first call whose args match <glob>.
if [ -n "\${SWAP:-}" ] && [[ "\$*" == \${SWAP_ON:-} ]] && [ ! -e "$T/swapped" ]; then
  : > "$T/swapped"; cp "\$SWAP" "\$SWAP.new" && mv -f "\$SWAP.new" "\$SWAP"
fi
if [ "\${PROBEMODE:-}" = hang ] && [[ "\$*" == *"-i"* ]] && [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then exec /bin/sleep 30; fi
if [ "\${HOLDMODE:-}" = hang ] && [[ "\$*" == *"issues/"* ]] && [[ "\$*" != *"-i"* ]]; then exec /bin/sleep 30; fi
if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then
  echo "\$*" >> "$T/pr-reads"
  case "\${PRMODE:-none}" in
    open) printf 'HTTP/1.1 200 OK\\n\\n[{"number":9,"html_url":"https://github.com/example-org/project-5/pull/9"}]\\n'; exit 0 ;;
    none) exit 1 ;;
    403) printf 'HTTP/1.1 403 Forbidden\\n\\n{"message":"rate limit"}\\n'; exit 0 ;;
    hang) exec /bin/sleep 30 ;;
    slow) /bin/sleep "\${PRDELAY:-2}" ;;
  esac
  printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0
fi
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"t","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
  chmod +x "$T/fakebin/gh"
}

passthrough_timeout() { printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"; }

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H"/flags/alerted-pool-pr-* "$T/pr-reads" \
           "$T/swapped" "$T/fly-calls" "$T/listing.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
queue_n() { # queue_n <first> <last> — rows BH-<n>, ticket id n
  local n
  for n in $(seq "$1" "$2"); do
    jq -nc --arg k "BH-$n" --arg t "$n" \
      '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0,enqueued_at:"2026-10-19T00:00:00Z"}' \
      > "$H/state/build-queue/project-5/BH-$n.json"
  done
}
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
spawned() { count '\] spawned .* for BH-' "$H/logs/fly-pool.log"; }
queued() { ls "$H/state/build-queue/project-5"/*.json 2>/dev/null | grep -c . ; }
code_stops() { count 'deployed pool code changed' "$H/logs/fly-pool.log"; }
age_stops() { count 'tick stopped at a row boundary: it has run' "$H/logs/fly-pool.log"; }
age_alerts() { count 'past POOL_TICK_MAX_AGE_S' "$H/logs/ALERTS.log"; }
lock_free() { flock -n "$H/locks/fly-pool-project-5.lock" true; }
LIB="$H/bin/lib/pool-tick-stop.sh"
PRREAD='*pulls?state=open*head=*'
write_fly_stub; write_gh_stub; passthrough_timeout

# ── A: the code changes during row 1 ─────────────────────────────────────────
reset_state; queue_n 3001 3004
run_pool PRMODE=ok SWAP="$LIB" SWAP_ON="$PRREAD"
[ -e "$T/swapped" ] && ok || bad "A: the stub never replaced the lib (no PR read?)"
[ "$(spawned)" = 1 ] && ok || bad "A: expected 1 spawn before the stop, got $(spawned): $(cat "$H/logs/fly-pool.log")"
[ "$(code_stops)" = 1 ] && ok || bad "A: expected ONE 'deployed pool code changed' line, got $(code_stops)"
grep -qE 'code changed since the tick started \(fp [0-9]+ -> [0-9]+\)' "$H/logs/fly-pool.log" && ok || bad "A: the stop line must print both fingerprints"
[ "$(queued)" = 3 ] && ok || bad "A: 3 rows must stay queued, got $(queued)"
[ "$RC" = 0 ] && ok || bad "A: rc $RC, want 0"
lock_free && ok || bad "A: the lock is still held after the tick exited"
[ "$(age_alerts)" = 0 ] && ok || bad "A: a code stop must not alert"

# ── B: near miss, an unnamed file is replaced ────────────────────────────────
reset_state; queue_n 3001 3004
run_pool PRMODE=ok SWAP="$H/bin/unrelated.sh" SWAP_ON="$PRREAD"
[ -e "$T/swapped" ] && ok || bad "B: the stub never replaced the file"
[ "$(spawned)" = 3 ] && ok || bad "B: an unnamed file must not stop the tick: $(spawned) spawned"
[ "$(code_stops)" = 0 ] && [ "$(age_stops)" = 0 ] && ok || bad "B: no stop line expected"

# ── C: past the max age ──────────────────────────────────────────────────────
reset_state; queue_n 3001 3004
# The first row boundary comes after start-up only (well under 8 s); the second
# comes after one 10 s PR read, so the stop lands on row 2 of the spawn walk.
run_pool PRMODE=slow PRDELAY=10 POOL_TICK_MAX_AGE_S=8
[ "$(count 'pulls?state=open' "$T/pr-reads")" = 1 ] && ok || bad "C: expected 1 row decided (1 PR read), got $(count . "$T/pr-reads")"
[ "$(age_stops)" = 1 ] && ok || bad "C: expected ONE stop line, got $(age_stops): $(cat "$H/logs/fly-pool.log")"
grep -qE 'it has run [0-9]+s, past POOL_TICK_MAX_AGE_S=8s' "$H/logs/fly-pool.log" && ok || bad "C: the stop line must print the age and the max"
[ "$(age_alerts)" = 1 ] && ok || bad "C: expected exactly ONE ALERTS line, got $(age_alerts): $(cat "$H/logs/ALERTS.log")"
grep 'past POOL_TICK_MAX_AGE_S' "$H/logs/ALERTS.log" | grep -F '[pool/project-5]' | grep -qE 'ran [0-9]+s' && ok || bad "C: the alert must name [pool/project-5] and the age"
[ "$RC" = 0 ] && ok || bad "C: rc $RC, want 0"
lock_free && ok || bad "C: the lock is still held"

# ── D: 0 = off ───────────────────────────────────────────────────────────────
reset_state; queue_n 3001 3004
run_pool PRMODE=slow POOL_TICK_MAX_AGE_S=0
[ "$(age_stops)" = 0 ] && [ "$(age_alerts)" = 0 ] && ok || bad "D: max age 0 must not stop"
[ "$(spawned)" = 3 ] && ok || bad "D: expected 3 spawns, got $(spawned)"

# ── E: the default (1200 s) does not stop a 2 s row ──────────────────────────
reset_state; queue_n 3001 3002
run_pool PRMODE=slow
[ "$(age_stops)" = 0 ] && [ "$(code_stops)" = 0 ] && ok || bad "E: the default must not stop a short tick"
[ "$(spawned)" = 2 ] && ok || bad "E: expected 2 spawns, got $(spawned)"

# ── F: control, the lock is real ─────────────────────────────────────────────
reset_state; queue_n 3001 3002
exec 9>"$H/locks/fly-pool-project-5.lock"; flock -n 9 || bad "F: could not take the lock"
run_pool PRMODE=ok
exec 9>&-
grep -q 'already running' "$H/logs/fly-pool.log" && ok || bad "F: a held lock must make the tick exit 'already running'"
[ "$(spawned)" = 0 ] && ok || bad "F: a held lock must spawn nothing, got $(spawned)"

# ── R: the code changes during the REAP walk ─────────────────────────────────
reset_state; queue_n 3001 3002
NOWZ=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for m in m1aaaaaaaaaaaa m2bbbbbbbbbbbb; do
  jq -nc --arg m "$m" --arg k "BH-${m:1:1}900" --arg ts "$NOWZ" \
    '{machine:$m,key:$k,ticket_id:"9",attempt:0,deferrals:0,deaths:0,spawned_at:$ts}' \
    > "$H/state/fly-pool/project-5/$m.json"
done
printf '[{"id":"m1aaaaaaaaaaaa","state":"started"},{"id":"m2bbbbbbbbbbbb","state":"started"}]\n' > "$T/listing.json"
run_pool PRMODE=ok SWAP="$LIB" SWAP_ON='*ssh console*m1aaaaaaaaaaaa*'
[ -e "$T/swapped" ] && ok || bad "R: the stub never replaced the lib (machine 1 not reaped?): $(cat "$T/fly-calls" 2>/dev/null)"
[ "$(code_stops)" = 1 ] && ok || bad "R: expected ONE code stop line in the reap walk, got $(code_stops): $(cat "$H/logs/fly-pool.log")"
! grep -q m2bbbbbbbbbbbb "$T/fly-calls" && ok || bad "R: machine 2 was visited after the stop: $(grep m2b "$T/fly-calls")"
! sed -n '/deployed pool code changed/,$p' "$H/logs/fly-pool.log" | grep -q m2bbbbbbbbbbbb && ok || bad "R: a log line after the stop names machine 2"
[ -f "$H/state/fly-pool/project-5/m2bbbbbbbbbbbb.json" ] && ok || bad "R: machine 2's file must stay for the next tick"
[ "$(spawned)" = 0 ] && ! grep -q 'machine run' "$T/fly-calls" && ok || bad "R: the spawn walk must not be entered, $(spawned) spawned"
! grep -q 'PR bulk read' "$H/logs/fly-pool.log" && ok || bad "R: the tick must exit after the REAP walk, before the spawn walk's preamble"
[ "$(queued)" = 2 ] && ok || bad "R: the queued rows must stay, got $(queued)"
[ "$RC" = 0 ] && ok || bad "R: rc $RC, want 0"
lock_free && ok || bad "R: the lock is still held"

# ── U1-U6: pts_stop_due on its own ───────────────────────────────────────────
# $U/bin/tick.sh sources the lib, calls pts_init from its top level (as
# fly-pool.sh does), then runs the case body given in $UCASE. It names
# lib/named-a.sh and lib/named-late.sh (absent at start); it does not name
# lib/unnamed.sh.
U="$T/u"; mkdir -p "$U/bin/lib" "$U/logs"
scratch_install_closure bin/lib/pool-tick-stop.sh "$U" >/dev/null || { echo "closure install of bin/lib/pool-tick-stop.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$U" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$U/bin/beat.sh"; chmod +x "$U/bin/beat.sh"
cat > "$U/bin/tick.sh" <<'TICK'
#!/bin/bash
P=project-5
. "$HARNESS/bin/lib/pool-tick-stop.sh"
. "$HARNESS/bin/lib/named-a.sh" 2>/dev/null
. "$HARNESS/bin/lib/named-late.sh" 2>/dev/null
pts_init
swap() { cp "$1" "$1.new" && mv -f "$1.new" "$1"; }  # replace by rename, as rsync does
eval "$UCASE"
TICK
ulog() { count 'tick stopped at a row boundary' "$U/logs/fly-pool.log"; }
ualerts() { count 'past POOL_TICK_MAX_AGE_S' "$U/logs/ALERTS.log"; }
u_run() { # u_run <case body> — prints the body's stdout, rc is the body's rc
  printf 'x\n' > "$U/bin/lib/named-a.sh"; printf 'y\n' > "$U/bin/lib/unnamed.sh"
  [ -e "$U/bin/lib/named-late.sh" ] && scratch_rm "$U/bin/lib/named-late.sh"
  : > "$U/logs/fly-pool.log"; : > "$U/logs/ALERTS.log"
  ( unset POOL_TICK_MAX_AGE_S H; HARNESS="$U" PTS_NOW=1800000000 UCASE="$1" bash "$U/bin/tick.sh" )
}

# U1: a named lib replaced by rename stops with reason code; so does a named lib
# that appears later, a named lib edited in place, and the script itself replaced.
OUT=$(u_run 'swap "$HARNESS/bin/lib/named-a.sh"; pts_stop_due; echo "rc=$? why=$PTS_STOP"')
[ "$OUT" = "rc=0 why=code" ] && ok || bad "U1: a renamed lib must stop with code, got '$OUT'"
[ "$(ulog)" = 1 ] && ok || bad "U1: expected one log line, got $(ulog)"
OUT=$(u_run 'echo z > "$HARNESS/bin/lib/named-late.sh"; pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=0" ] && ok || bad "U1: a named lib that appears later must stop, got '$OUT'"
OUT=$(u_run 'echo more >> "$HARNESS/bin/lib/named-a.sh"; pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=0" ] && ok || bad "U1: a lib edited in place must stop, got '$OUT'"
OUT=$(u_run 'swap "$HARNESS/bin/tick.sh"; pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=0" ] && ok || bad "U1: the script replaced by rename must stop, got '$OUT'"

# U2: a read of a lib and a replaced UNNAMED lib do not stop.
OUT=$(u_run 'cat "$HARNESS/bin/lib/named-a.sh" >/dev/null; . "$HARNESS/bin/lib/named-a.sh" 2>/dev/null; swap "$HARNESS/bin/lib/unnamed.sh"; touch "$HARNESS/logs/x"; pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U2: a read or an unnamed file must not stop, got '$OUT'"
[ "$(ulog)" = 0 ] && ok || bad "U2: nothing must be logged"

# U3: nothing changed and age < max.
OUT=$(u_run 'POOL_TICK_MAX_AGE_S=100; PTS_T0=$((PTS_T0 - 50)); pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U3: no change, age 50 < 100 must not stop, got '$OUT'"

# U4: age == max stops with one log line and one alert; a second call returns 0
# and writes nothing; code change and age together report age.
OUT=$(u_run 'POOL_TICK_MAX_AGE_S=30; PTS_T0=$((PTS_T0 - 30)); echo more >> "$HARNESS/bin/lib/named-a.sh"; pts_stop_due; a=$?; pts_stop_due; echo "rc=$a,$? why=$PTS_STOP"')
[ "$OUT" = "rc=0,0 why=age" ] && ok || bad "U4: age == max must stop as age, and a second call too, got '$OUT'"
[ "$(ulog)" = 1 ] && ok || bad "U4: expected ONE log line over two calls, got $(ulog)"
[ "$(ualerts)" = 1 ] && ok || bad "U4: expected ONE alert over two calls, got $(ualerts)"
grep -F '[pool/project-5] tick ran 30s, past POOL_TICK_MAX_AGE_S=30s' "$U/logs/ALERTS.log" >/dev/null && ok || bad "U4: the alert must name the project and the age: $(cat "$U/logs/ALERTS.log")"
OUT=$(u_run 'POOL_TICK_MAX_AGE_S=0; PTS_T0=$((PTS_T0 - 1000000)); pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U4: max 0 is off even at age 10^6, got '$OUT'"

# U5: a garbage knob falls back to 1200; -5 reads as 5 (digits only).
OUT=$(u_run 'POOL_TICK_MAX_AGE_S=abc; PTS_T0=$((PTS_T0 - 5)); pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U5: knob abc must fall back to 1200 (age 5 no stop), got '$OUT'"
OUT=$(u_run 'POOL_TICK_MAX_AGE_S=-5; PTS_T0=$((PTS_T0 - 6)); pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=0" ] && ok || bad "U5: knob -5 reads as 5, age 6 must stop, got '$OUT'"
OUT=$(u_run 'pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U5: unset knob, fresh tick must not stop, got '$OUT'"

# U6: an empty start fingerprint turns the code check off.
OUT=$(u_run 'PTS_FP0=""; echo more >> "$HARNESS/bin/lib/named-a.sh"; pts_stop_due; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "U6: an empty PTS_FP0 must not stop, got '$OUT'"
[ "$(ulog)" = 0 ] && ok || bad "U6: nothing must be logged"
# U6: no root (HARNESS and H unset): pts_init refuses, pts_stop_due never stops.
OUT=$( ( unset HARNESS H; P=project-5 PTS_NOW=1800000000; . "$U/bin/lib/pool-tick-stop.sh"; pts_init; a=$?; PTS_T0=1; pts_stop_due; echo "rc=$a,$?" ) )
[ "$OUT" = "rc=1,1" ] && ok || bad "U6: with no root pts_init must return 1 and pts_stop_due 1, got '$OUT'"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
