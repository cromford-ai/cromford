#!/bin/bash
# tests/pool-after-release.bh-5967-test.sh — BH-5967 parts 1 and 2: a pool
# deferral that names its blocker (`After: <KEY>`) is a wait, never a park, and
# the row is re-offered on the tick its blocker is done.
#
# THE CENSUS (2026-10-10). 39 of 95 open cromford tickets had no open PR,
# no blocker and no hold, and nothing built them. A pool build that overlapped
# an open PR stood down `BUILD_DEFERRED ... After: <KEY>`; past
# JOBS_QUEUE_DEFER_MAX the row turned FAILED "parked for the blocked-resolver",
# which reached about one project per 100 minutes. #5521 and #5888 waited on
# #5890 hours after it merged.
#
#   A1  13 stand-downs on an open blocker leave the row queued (DEFERRED), with
#       `after` and the count kept, not FAILED; one AFTER LOOP page at 12
#   A2  the next stand-down on the same blocker does not page again
#   A3  a stand-down that names no blocker still parks at JOBS_QUEUE_DEFER_MAX
#   B1  a row waiting on BH-890 whose PR is open: no machine, row unchanged
#   B2  BH-890 still queued in this pool: no machine
#   B3  BH-890's PR merged and nothing in flight: released in this tick — a
#       fresh queue row with deferrals 0, `after` dropped, and a machine spawned
#   B4  BH-890's PR read does not answer: no machine, the row waits
#   C1  a 2-cycle (BH-1016 waits for BH-890, BH-890 for BH-1016): the
#       byte-smaller key (BH-1016) is released, the other keeps waiting
#   C2  a 3-cycle (BH-1016 -> BH-890 -> BH-900 -> BH-1016): only BH-1016 goes
#   C3  a hold older than POOL_AFTER_MAX_MIN (360) is released with ONE alert
#   C4  a row released twice for the same blocker keeps its deferral count on
#       the third release, and its next stand-down at or over
#       JOBS_QUEUE_DEFER_MAX PARKS (the cap acts, with one alert)
#   C5  three release cycles on the same blocker give ONE AFTER LOOP line
#   C6  C2 with the BH-1016 spawn caught between its queue-file move and its
#       pool-json write: BH-900 still waits (BH-1016 is in flight this tick)
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh and a recording jobs client.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes: the row is the thing under test.
# Executed (a setting read) it answers nothing, so every setting falls back.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC

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
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=fixture-fly-token FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}
# gh: the repo is visible; ticket/bh-890's open-PR list is $T/pr-890 (open,
# none or broken); ticket/bh-1016 has no PR; the hold read finds an ai-build
# issue with no comments.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/1016"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"TS fixture","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"ticket/bh-890"* ]]; then
    case "\$(cat "$T/pr-890" 2>/dev/null)" in
      open)   printf 'HTTP/1.1 200 OK\\n\\n[{"number":890,"html_url":"https://github.com/example-org/project-5/pull/890"}]\\n' ;;
      broken) printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n' ;;
      *)      printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
    esac
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# machine_json <mid> <deferrals> — a live machine for BH-1016 whose RESULT is read.
machine_json() {
  jq -nc --arg m "$1" --argjson d "$2" \
    '{machine:$m,key:"BH-1016",ticket_id:"1016",attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-10-10T13:20:00Z"}' \
    > "$H/state/fly-pool/project-5/$1.json"
}
QF="$H/state/build-queue/project-5/BH-1016.json"
qf() { jq -r "$1" "$QF" 2>/dev/null || echo no-queue-file; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null; }
AFTER_LINE="BUILD_DEFERRED After: BH-890 in flight — BH-1016 overlaps it on a non-splittable file and builds after it merges; re-checked each tick before any plan is bought"

# ── A1: 13 stand-downs on an open blocker stay a wait ─────────────────────
reset_state; echo open > "$T/pr-890"
write_fly_stub "$AFTER_LINE"
machine_json m-a1 12
run_pool JOBS_QUEUE_DEFER_MAX=6
[ "$(qf '.deferrals')" = 13 ] && [ "$(qf '.after')" = BH-890 ] && ok \
  || bad "A1: THE BUG: 13 stand-downs on BH-890 must leave a queued row with after=BH-890, deferrals=13 (queue file: $(cat "$QF" 2>/dev/null || echo none))"
grep -q 'parked for the blocked-resolver' "$H/logs/ALERTS.log" && bad "A1: a wait on a named blocker was parked: $(grep parked "$H/logs/ALERTS.log")" || ok
grep -q '^done project-5 BH-1016 failed' "$T/q.log" && grep -q '^put project-5 BH-1016 1016 fly' "$T/q.log" && ok \
  || bad "A1: the row is closed and re-queued, not left FAILED (q.log: $(tr '\n' '|' < "$T/q.log"))"
grep -q '"after":"BH-890"' "$T/q.log" && ok || bad "A1: the re-queued row's meta carries the blocker (q.log: $(tr '\n' '|' < "$T/q.log"))"
[ "$(grep -c 'AFTER LOOP' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A1: one AFTER LOOP page at DEFER_AFTER_LOOP_ALERT=12 (ALERTS: $(cat "$H/logs/ALERTS.log"))"

# ── A2: the next stand-down on the same blocker does not page again ───────
scratch_rm "$QF"; : > "$H/logs/ALERTS.log"
machine_json m-a2 13
run_pool JOBS_QUEUE_DEFER_MAX=6
[ "$(qf '.deferrals')" = 14 ] && ok || bad "A2: still a wait at 14 (queue file: $(cat "$QF" 2>/dev/null || echo none))"
[ "$(grep -c 'AFTER LOOP' "$H/logs/ALERTS.log")" = 0 ] && ok || bad "A2: the AFTER LOOP page is said once per blocker (ALERTS: $(cat "$H/logs/ALERTS.log"))"

# ── A3: a stand-down that names no blocker still parks ────────────────────
reset_state
write_fly_stub "BUILD_DEFERRED BH-1016 already building"
machine_json m-a3 12
run_pool JOBS_QUEUE_DEFER_MAX=6
grep -q '^done project-5 BH-1016 failed deferred 13 times .*parked for the blocked-resolver' "$T/q.log" && [ ! -e "$QF" ] && ok \
  || bad "A3: a plain deferral past the cap is parked, as before (queue file: $(cat "$QF" 2>/dev/null || echo none))"

# The B cases: no live machine; BH-1016 waits in the queue for BH-890.
qwait() { jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:13,deaths:0,enqueued_at:"2026-10-10T13:00:00Z",after:"BH-890"}' > "$QF"; }

# ── B1: the blocker's PR is open: no machine ──────────────────────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-890"; qwait
run_pool
[ "$(spawned)" = 0 ] && ok || bad "B1: no machine while BH-890's PR is open ($(spawned) spawned)"
[ "$(qf '.after')" = BH-890 ] && [ "$(qf '.deferrals')" = 13 ] && ok || bad "B1: the row is unchanged ($(cat "$QF" 2>/dev/null))"
grep -q 'skipping BH-1016: waits for BH-890' "$H/logs/fly-pool.log" && ok || bad "B1: one line says why: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"

# ── B2: the blocker is still queued in this pool: no machine ──────────────
reset_state; write_fly_stub ""; echo none > "$T/pr-890"; qwait
jq -nc '{ticket_id:"890",key:"BH-890",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-10T13:00:00Z"}' > "$H/state/build-queue/project-5/BH-890.json"
run_pool
grep -q 'skipping BH-1016: waits for BH-890' "$H/logs/fly-pool.log" && ok || bad "B2: a blocker still queued holds the row: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"

# ── B3: the blocker merged: released and spawned this tick ────────────────
reset_state; write_fly_stub ""; echo none > "$T/pr-890"; qwait
run_pool
grep -q 'RELEASED BH-1016: BH-890 is done' "$H/logs/fly-pool.log" && ok || bad "B3: THE BUG: the row is released the tick BH-890 is done: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -3)"
grep -q '^put project-5 BH-1016 1016 fly 1 {"deferrals":0}' "$T/q.log" && ok \
  || bad "B3: a fresh queue row with the count reset (q.log: $(tr '\n' '|' < "$T/q.log"))"
[ "$(spawned)" -ge 1 ] && ok || bad "B3: a machine is spawned in the same tick ($(spawned))"
PJ=$(grep -ls '"key":"BH-1016"' "$H/state/fly-pool/project-5/"*.json 2>/dev/null | head -n 1)
[ -n "$PJ" ] && [ "$(jq -r '.deferrals' "$PJ")" = 0 ] && ok || bad "B3: the spawned machine carries deferrals 0 ($(cat "$PJ" 2>/dev/null || echo 'no pool json'))"

# ── B4: the blocker's PR read does not answer: the row waits ──────────────
reset_state; write_fly_stub ""; echo broken > "$T/pr-890"; qwait
run_pool
[ "$(spawned)" = 0 ] && ok || bad "B4: no machine on an unreadable PR answer ($(spawned))"
grep -q 'its PR read did not answer' "$H/logs/fly-pool.log" && ok || bad "B4: the line says the read did not answer: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"

# Cycle and ceiling fixtures: queue files that wait on each other.
qwaitk() { # qwaitk <key> <ticket> <after> [deferrals]
  jq -nc --arg k "$1" --arg t "$2" --arg a "$3" --argjson d "${4:-13}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:$d,deaths:0,enqueued_at:"2026-10-10T13:00:00Z",after:$a}' \
    > "$H/state/build-queue/project-5/$1.json"
}
# ── C1: a 2-cycle releases the byte-smaller key ───────────────────────────
reset_state; write_fly_stub ""; echo none > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; qwaitk BH-890 890 BH-1016
run_pool
grep -q 'RELEASED BH-1016: .*mutual' "$H/logs/fly-pool.log" && ok || bad "C1: THE BUG: BH-1016 (byte-smaller) is released from the 2-cycle: $(grep -E 'BH-1016|BH-890' "$H/logs/fly-pool.log" | tail -3)"
grep -q 'RELEASED BH-890' "$H/logs/fly-pool.log" && bad "C1: BH-890 must keep waiting: $(grep 'RELEASED BH-890' "$H/logs/fly-pool.log")" || ok
grep -q 'skipping BH-890: waits for BH-1016' "$H/logs/fly-pool.log" && ok || bad "C1: BH-890 is held this tick: $(grep BH-890 "$H/logs/fly-pool.log" | tail -2)"

# ── C2: a 3-cycle releases only its smallest key ──────────────────────────
reset_state; write_fly_stub ""
qwaitk BH-1016 1016 BH-890; qwaitk BH-890 890 BH-900; qwaitk BH-900 900 BH-1016
run_pool
grep -q 'RELEASED BH-1016: .*mutual' "$H/logs/fly-pool.log" && ok || bad "C2: BH-1016 is released from the 3-cycle: $(grep RELEASED "$H/logs/fly-pool.log")"
[ "$(grep -c 'RELEASED' "$H/logs/fly-pool.log")" = 1 ] && ok || bad "C2: exactly one key leaves the cycle: $(grep RELEASED "$H/logs/fly-pool.log")"

# ── C3: past the ceiling, the hold is released with one alert ─────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-890"; qwait
printf 'BH-890\t%s\n' "$((NOW - 7 * 3600))" > "$H/state/pool/project-5/BH-1016.after-since"
run_pool
grep -q 'RELEASED BH-1016: .*ceiling' "$H/logs/fly-pool.log" && ok || bad "C3: a 7-hour hold is released at the 360-minute ceiling: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
[ "$(grep -c 'AFTER CEILING' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "C3: one AFTER CEILING alert: $(grep -c 'AFTER CEILING' "$H/logs/ALERTS.log")"
[ "$(spawned)" -ge 1 ] && ok || bad "C3: the released row spawns"
reset_state; write_fly_stub ""; echo open > "$T/pr-890"; qwait
run_pool
grep -q 'skipping BH-1016: waits for BH-890' "$H/logs/fly-pool.log" && ok || bad "C3: a fresh hold starts its own clock and waits: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
[ -s "$H/state/pool/project-5/BH-1016.after-since" ] && ok || bad "C3: the first held tick starts the clock"

# ── C4: the third release for the same blocker keeps the count ────────────
reset_state; write_fly_stub ""; echo none > "$T/pr-890"; qwait
printf 'BH-890\t2\t%s\n' "$((NOW - 600))" > "$H/state/pool/project-5/BH-1016.after-released"
run_pool
grep -q '^put project-5 BH-1016 1016 fly 1 {"deferrals":13}' "$T/q.log" && ok \
  || bad "C4: a third release for BH-890 keeps deferrals=13 (q.log: $(tr '\n' '|' < "$T/q.log"))"

# C4b — the kept count makes the cap act: the next stand-down on BH-890 is at
# 14 >= JOBS_QUEUE_DEFER_MAX=6, and the row parks once (review of 22e7719c5:
# the probe reached 16 with a cap of 6).
reset_state; write_fly_stub "$AFTER_LINE"; echo open > "$T/pr-890"
printf 'BH-890\t3\t%s\n' "$((NOW - 600))" > "$H/state/pool/project-5/BH-1016.after-released"
machine_json m-c4 13
run_pool JOBS_QUEUE_DEFER_MAX=6
grep -q '^done project-5 BH-1016 failed deferred 14 times .*parked for the blocked-resolver' "$T/q.log" && [ ! -e "$QF" ] && ok \
  || bad "C4: THE BUG: after three releases on BH-890 the cap must park the row (q.log: $(tr '\n' '|' < "$T/q.log"); queue file: $(cat "$QF" 2>/dev/null || echo none))"
[ "$(grep -c 'queue row is FAILED' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "C4: one park alert: $(grep -c 'queue row is FAILED' "$H/logs/ALERTS.log")"

# ── C5: three release cycles on one blocker give ONE AFTER LOOP line ──────
reset_state; : > "$T/alerts-c5.log"
for _c in 1 2 3; do
  # A stand-down at 12 (DEFER_AFTER_LOOP_ALERT=12)...
  write_fly_stub "$AFTER_LINE"; echo open > "$T/pr-890"; : > "$H/logs/ALERTS.log"
  machine_json "m-c5-$_c" 11
  run_pool JOBS_QUEUE_DEFER_MAX=50
  cat "$H/logs/ALERTS.log" >> "$T/alerts-c5.log"
  # ...then BH-890 is done and the gate releases the row.
  write_fly_stub ""; echo none > "$T/pr-890"
  run_pool JOBS_QUEUE_DEFER_MAX=50
  grep -q 'RELEASED BH-1016' "$H/logs/fly-pool.log" || bad "C5 setup: cycle $_c did not release the row: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
  scratch_rm "$QF" 2>/dev/null; for _m in "$H/state/fly-pool/project-5/"*.json; do [ -e "$_m" ] && scratch_rm "$_m"; done
done
[ "$(grep -c 'AFTER LOOP' "$T/alerts-c5.log")" = 1 ] && ok \
  || bad "C5: THE BUG: three release cycles on BH-890 must give ONE AFTER LOOP line, got $(grep -c 'AFTER LOOP' "$T/alerts-c5.log")"

# ── C6: a key spawned this tick is in flight before its pool json exists ──
# spawn_one runs in the background: it moves the queue file away, then writes
# the pool json. The flake in merge batch #7221 (C2, 3 of 24 runs under load)
# was a later row's gate reading BH-1016 in that gap as "done". A fake jq pins
# the gap open: the read of BH-900's key waits until BH-1016's queue file is
# gone, and the pool-json write waits until BH-900's gate has said its line.
# Bounded polls, no fixed sleep.
REALJQ=$(command -v jq)
cat > "$T/fakebin/jq" <<FJQ
#!/bin/bash
case "\$*" in
  *spawned_at*)
    for _i in \$(seq 1 100); do
      grep -qE '(skipping|RELEASED) BH-900' "$H/logs/fly-pool.log" 2>/dev/null && break
      /bin/sleep 0.05
    done ;;
  *'.key // ""'*BH-900.json*)
    for _i in \$(seq 1 100); do
      [ -e "$H/state/build-queue/project-5/BH-1016.json" ] || break
      /bin/sleep 0.05
    done ;;
esac
exec "$REALJQ" "\$@"
FJQ
chmod +x "$T/fakebin/jq"
reset_state; write_fly_stub ""
qwaitk BH-1016 1016 BH-890; qwaitk BH-890 890 BH-900; qwaitk BH-900 900 BH-1016
run_pool
rm -f "$T/fakebin/jq"
grep -q 'RELEASED BH-1016: .*mutual' "$H/logs/fly-pool.log" && ok || bad "C6: BH-1016 is released from the 3-cycle: $(grep RELEASED "$H/logs/fly-pool.log")"
grep -q 'RELEASED BH-900' "$H/logs/fly-pool.log" && bad "C6: THE BUG: BH-1016 was spawned this tick, so BH-900 must keep waiting: $(grep 'RELEASED BH-900' "$H/logs/fly-pool.log")" || ok
grep -q 'skipping BH-900: waits for BH-1016' "$H/logs/fly-pool.log" && ok || bad "C6: BH-900 is held this tick: $(grep BH-900 "$H/logs/fly-pool.log" | tail -2)"

echo "pool-after-release.bh-5967: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
