#!/bin/bash
# tests/fly-pool-sibling-serial.bh-6374-test.sh — the fleet pool does not spawn
# a sibling part (TK-142.2) while a sibling with a colliding pre-plan list
# (TK-142.1) is in flight or queued ahead of it (BH-6374).
#
#   P1  .1 on a machine, .2 queued, same file: no machine for .2, the row stays
#       queued, no spawn recorded, and fly-pool.log names the wait
#   P2  a non-part key queued beside it spawns
#   P3  .1's machine gone: .2 spawns and its wait clock is removed
#   P4  bin/sibling-serial.sh check: a queued .1 older than
#       SIBLING_QUEUED_MAX_MIN does not hold .2; a fresh one does
#   P5  a wait older than SIBLING_SERIAL_MAX_MIN releases the key, logs
#       SIBLING_SERIAL_RELEASED and alerts once over two ticks
#   P6  SIBLING_SERIAL=0 spawns .2 on the P1 fixture
#   P7  the reuse handoff (next_job_or_destroy) runs the same gate
#
# HOW IT DRIVES: the real bin/fly-pool.sh as a subprocess against a scratch
# harness with fly stubs (the tests/fly-pool-overlap-defer-uncounted.bh-5912-
# test.sh scaffold). The project has no repo slug, so the GitHub spawn gates are
# inactive: the sibling gate runs before them and must hold on its own. The
# clock is pinned through SIBLING_SERIAL_NOW.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
NOW=1791860000   # 2026-10-13, pinned

H="$T/h"
QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"; MD="$H/state/fly-pool/project-5"
# The wait clock is box-local, not a pool row (catalog/state-paths.json).
SD="$H/state/sibling-serial/project-5"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/project-5" \
         "$PD" "$SD" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 - - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The alert stub is written BEFORE the closure installs, which never clobbers it.
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || bad "closure install of bin/sibling-serial.sh failed"
# The jobs client, so the job_claims rows can be read (P4c). With no JOBS_URL
# configured, every other case reads as before: no worker.
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure install of bin/jobs-client.sh failed"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
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
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" \
         "$H/bin/alert-line.sh" "$T/fakebin"/*

write_fly_stub() { # write_fly_stub [RESULT] [only-machine]
  local result="${1:-}" only="${2:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"$only"*"head"*"RESULT"*|*"ssh console"*"head"*"RESULT"*"$only"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" \
           SIBLING_SERIAL_NOW="$NOW" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$SD"/* "$H/plans"/* "$T/alert-calls" "$T/fly-calls"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/project-5-$k"
  printf '%s\n' "$@" > "$H/plans/project-5-$k/planned-files.txt"
}
queue() { # queue <KEY> <ticket-id> [enqueued_at]
  jq -nc --arg k "$1" --arg t "$2" --arg e "${3:-2026-10-13T02:30:00Z}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:$e}' > "$QD/$1.json"
}
machine() { # machine <id> <KEY> <ticket-id> — a live machine building KEY
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-13T02:30:00Z"}' \
    > "$MD/$1.json"
}
machine_for() { grep -ls "\"key\": *\"$1\"" "$MD"/*.json 2>/dev/null | grep -c .; }
spawns_of() { grep -c . "$PD/$1.spawns" 2>/dev/null || echo 0; }

# P1 fixture: TK-142.1 on a machine, TK-142.2 queued, both plan src/x/board.tsx
p1_fixture() {
  reset_state
  write_fly_stub ""
  plan_files TK-142.1 src/x/board.tsx src/x/a.ts
  plan_files TK-142.2 src/x/board.tsx src/x/b.ts
  machine m-one TK-142.1 1421
  queue TK-142.2 1422
}

# ── P1 ──────────────────────────────────────────────────────────────────────
p1_fixture
run_pool
[ "$(machine_for TK-142.2)" = 0 ] && ok || bad "P1: a machine was spawned for TK-142.2 beside a live TK-142.1"
[ -f "$QD/TK-142.2.json" ] && ok || bad "P1: TK-142.2's queue file must stay"
[ "$(spawns_of TK-142.2)" = 0 ] && ok || bad "P1: a wait must not record a spawn ($(spawns_of TK-142.2))"
[ "$(grep -c 'SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx' "$H/logs/fly-pool.log")" = 1 ] && ok \
  || bad "P1: expected one SIBLING_SERIAL line in fly-pool.log, got: $(cat "$H/logs/fly-pool.log")"
grep -q 'no pre-plan list' "$H/logs/fly-pool.log" && bad "P1: a listed wait must not read as the no-list fallback" || ok
[ -s "$SD/TK-142.2.sibling-since" ] && ok || bad "P1: the wait clock was not started"
grep -q 'SIBLING' "$H/logs/ALERTS.log" && bad "P1: a sibling wait is not an alert" || ok
grep -q 'machine run' "$T/fly-calls" 2>/dev/null && bad "P1: fly machine run was called" || ok

# ── P2: a non-part key in the same queue spawns ────────────────────────────
p1_fixture
plan_files BH-1016 src/x/board.tsx
queue BH-1016 1016
run_pool
[ "$(machine_for BH-1016)" = 1 ] && ok || bad "P2: the non-part key BH-1016 must spawn: $(cat "$H/logs/fly-pool.log")"
[ "$(machine_for TK-142.2)" = 0 ] && ok || bad "P2: TK-142.2 must still wait"

# ── P3: .1's machine gone -> .2 spawns, the clock is removed ───────────────
p1_fixture
printf 'TK-142.1\t%s\n' "$((NOW-600))" > "$SD/TK-142.2.sibling-since"
scratch_rm "$MD/m-one.json"
run_pool
[ "$(machine_for TK-142.2)" = 1 ] && ok || bad "P3: TK-142.2 must spawn once .1 is done: $(cat "$H/logs/fly-pool.log")"
[ -e "$SD/TK-142.2.sibling-since" ] && bad "P3: the wait clock must be removed on go" || ok

# ── P4: the check verb, a stale queued .1 vs a fresh one ───────────────────
reset_state
plan_files TK-142.1 src/x/board.tsx
plan_files TK-142.2 src/x/board.tsx
queue TK-142.1 1421 "$(date -u -d "@$((NOW-3*3600))" +%Y-%m-%dT%H:%M:%SZ)"
queue TK-142.2 1422
OUT=$(HARNESS="$H" SIBLING_SERIAL_NOW="$NOW" "$H/bin/sibling-serial.sh" check project-5 TK-142.2 2>"$T/err"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4: a 3h-old queued .1 must not hold .2 (rc $RC, out '$OUT')"
grep -q 'TK-142.1' "$T/err" && ok || bad "P4: the stale sibling must be named on stderr, got: $(cat "$T/err")"
queue TK-142.1 1421 "$(date -u -d "@$((NOW-600))" +%Y-%m-%dT%H:%M:%SZ)"
OUT=$(HARNESS="$H" SIBLING_SERIAL_NOW="$NOW" "$H/bin/sibling-serial.sh" check project-5 TK-142.2 2>/dev/null); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx" ] && ok \
  || bad "P4: a fresh queued .1 must hold .2 (rc $RC, out '$OUT')"
OUT=$(HARNESS="$H" SIBLING_SERIAL_NOW="$NOW" "$H/bin/sibling-serial.sh" check project-5 TK-142.1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4: the lower part .1 never waits for .2 (rc $RC, out '$OUT')"
OUT=$(HARNESS="$H" "$H/bin/sibling-serial.sh" check project-5 BH-1016 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4: a non-part key is rc 0 and silent (rc $RC, out '$OUT')"

chk() { HARNESS="$H" SIBLING_SERIAL_NOW="$NOW" "$@" "$H/bin/sibling-serial.sh" check project-5 TK-142.2 2>"$T/err"; }

# P4b: an open sibling PR from the overlap-guard cache, fresh and stale
reset_state
plan_files TK-142.2 src/x/board.tsx
queue TK-142.2 1422
mkdir -p "$H/state/overlap-guard"
jq -nc '[{number:11, headRefName:"ticket/TK-142.1", isDraft:false, files:[{path:"src/x/board.tsx"}]}]' \
  > "$H/state/overlap-guard/project-5-prs.json"
OUT=$(chk env); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx stackable base=ticket/TK-142.1" ] && ok \
  || bad "P4b: a fresh cache with .1's PR must hold .2 (rc $RC, out '$OUT')"
touch -d '20 minutes ago' "$H/state/overlap-guard/project-5-prs.json"
OUT=$(chk env); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4b: a stale cache is no PR rows (rc $RC, out '$OUT')"
grep -q 'TK-142.2 prs=unread' "$T/err" && ok || bad "P4b: a go on a stale cache says prs=unread, got: $(cat "$T/err")"
scratch_rm "$H/state/overlap-guard"

# P4c: the job_claims rows (BH-5002) are the claims source. A row for .1 holds
# .2. TEST-CHANGE (state-paths guard on #6419): the old P4c pinned a fallback
# to state/claims/<p>/ files when the worker did not answer; the rows are the
# record, so an outage now judges no claim (one note line) and a leftover file
# is never read.
reset_state
plan_files TK-142.2 src/x/board.tsx
queue TK-142.2 1422
mkdir -p "$T/claimsbin"
cat > "$T/claimsbin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/file-claims\?project=project-5*)
    jq -nc '{claims:[{ticket_id:"TK-142.1", files_claimed_at:"2026-10-13T02:30:00Z", planned_files:"src/x/board.tsx"}]}'
    printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
chmod +x "$T/claimsbin/curl"
OUT=$(chk env PATH="$T/claimsbin:$PATH" JOBS_URL=http://worker.test HARNESS_SECRET=x); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx" ] && ok \
  || bad "P4c: a job_claims row for .1 must hold .2 (rc $RC, out '$OUT', err $(tail -2 "$T/err"))"
mkdir -p "$H/state/claims/project-5"
printf 'src/x/board.tsx\n' > "$H/state/claims/project-5/TK-142.1"
OUT=$(chk env); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "P4c: with the rows unread a state/claims file is not read (rc $RC, out '$OUT')"
grep -q 'TK-142.2 claims=unread' "$T/err" && ok || bad "P4c: an unread job_claims says so, got: $(cat "$T/err")"
scratch_rm "$H/state/claims/project-5"

# P4d: SIBLING_QUEUED_MAX_MIN=0 — a queued sibling never holds
reset_state
plan_files TK-142.1 src/x/board.tsx
plan_files TK-142.2 src/x/board.tsx
queue TK-142.1 1421 "$(date -u -d "@$((NOW-600))" +%Y-%m-%dT%H:%M:%SZ)"
queue TK-142.2 1422
OUT=$(chk env SIBLING_QUEUED_MAX_MIN=0); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4d: SIBLING_QUEUED_MAX_MIN=0 (rc $RC, out '$OUT')"

# P4e: flags/sibling-serial-off is the same kill switch
touch "$H/flags/sibling-serial-off"
OUT=$(chk env LANE_GATE_DISABLE=1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4e: flags/sibling-serial-off (rc $RC, out '$OUT')"
rm -f "$H/flags/sibling-serial-off"

# P4f: SIBLING_SERIAL_MAX_MIN=0 — no ceiling, a long wait still waits
printf 'TK-142.1\t%s\n' "$((NOW-9999*60))" > "$SD/TK-142.2.sibling-since"
OUT=$(chk env SIBLING_SERIAL_MAX_MIN=0); RC=$?
[ "$RC" = 3 ] && ok || bad "P4f: SIBLING_SERIAL_MAX_MIN=0 must not release (rc $RC, out '$OUT')"
# … and a new blocker restarts the clock
printf 'TK-142.0\t%s\n' "$((NOW-9999*60))" > "$SD/TK-142.2.sibling-since"
OUT=$(chk env); RC=$?
[ "$RC" = 3 ] && [ "$(cut -f2 "$SD/TK-142.2.sibling-since")" = "$NOW" ] && ok \
  || bad "P4f: a new blocker restarts the clock (rc $RC, since '$(cat "$SD/TK-142.2.sibling-since")')"

# ── P5: the ceiling releases once and alerts once over two ticks ───────────
p1_fixture
printf 'TK-142.1\t%s\n' "$((NOW-361*60))" > "$SD/TK-142.2.sibling-since"
run_pool
[ "$(machine_for TK-142.2)" = 1 ] && ok || bad "P5: TK-142.2 must spawn at the ceiling: $(cat "$H/logs/fly-pool.log")"
grep -q 'SIBLING_SERIAL_RELEASED TK-142.2 after 361 min behind TK-142.1' "$H/logs/fly-pool.log" && ok \
  || bad "P5: no SIBLING_SERIAL_RELEASED line: $(cat "$H/logs/fly-pool.log")"
# tick 2: .2 is queued again behind the same live .1
for f in "$MD"/*.json; do
  [ "$(jq -r .key "$f")" = TK-142.2 ] && scratch_rm "$f"
done
queue TK-142.2 1422
run_pool
[ "$(machine_for TK-142.2)" = 1 ] && ok || bad "P5: tick 2 must release again: $(cat "$H/logs/fly-pool.log"; cat "$T/alert-calls")"
[ "$(grep -c 'SIBLING_SERIAL_RELEASED' "$T/alert-calls" 2>/dev/null)" = 1 ] && ok \
  || bad "P5: expected exactly 1 alert over two ticks, got: $(cat "$T/alert-calls" 2>/dev/null)"

# ── P6: the kill switch ────────────────────────────────────────────────────
p1_fixture
run_pool SIBLING_SERIAL=0
[ "$(machine_for TK-142.2)" = 1 ] && ok || bad "P6: SIBLING_SERIAL=0 must spawn TK-142.2: $(cat "$H/logs/fly-pool.log")"
grep -q 'SIBLING_SERIAL TK-142.2' "$H/logs/fly-pool.log" && bad "P6: no wait line with the switch off" || ok

# ── P7: the reuse handoff runs the same gate ───────────────────────────────
# .3 is reaped (refused) and the queue holds .2; .1 is live on another
# machine, so the handoff must not give .2 to the reaped machine.
p1_fixture
write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running" m-reuse
plan_files TK-142.3 src/x/c.ts
machine m-reuse TK-142.3 1423
run_pool POOL_SPAWN=0
RK=$(jq -r '.key // ""' "$MD/m-reuse.json" 2>/dev/null)
[ "$RK" != TK-142.2 ] && ok || bad "P7: the handoff gave TK-142.2 to the reaped machine"
[ -f "$QD/TK-142.2.json" ] && ok || bad "P7: TK-142.2's row must stay queued"
grep -q 'SIBLING_SERIAL TK-142.2 waits for TK-142.1' "$H/logs/fly-pool.log" && ok \
  || bad "P7: the handoff did not log the sibling wait: $(cat "$H/logs/fly-pool.log")"

echo "fly-pool-sibling-serial: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
