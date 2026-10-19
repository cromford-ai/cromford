#!/bin/bash
# tests/fly-pool-pr-unreadable.bh-7421-test.sh — a pool tick whose PR reads do
# not answer (hub load 170-197 on 4 vCPU) must not walk every queued row (BH-7421).
#
#   A  PR reads unreadable, 6 new rows: ONE PR read in the tick, ONE alert, and
#      new rows (no spawn record, no terminal, attempt 1) spawn up to the pool
#      cap (3), with a logged decision
#   B  PR reads unreadable, 3 rows with a prior spawn record: none spawns, ONE
#      PR read in the tick, the rows stay queued
#   C  a PR read that hangs is cut at POOL_GH_READ_TIMEOUT_S and reads as unreadable
#   D  POOL_TICK_BUDGET_S spent: the tick stops walking rows, logs it, exits
#   F  a read that answers 403 (rate limit) keeps a new row waiting, with one PR read
#   E  a second tick inside the hour raises no second alert
# determinism: ok-file the sleeps are the stub gh's deliberate hang or delay (the
# thing under test is the cut), never synchronisation; the clock reads only time the tick.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

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
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
scratch_install_closure bin/lib/flags.sh "$H" >/dev/null || { echo "closure install of bin/lib/flags.sh failed"; exit 1; }
scratch_install_closure bin/lib/hold.sh "$H" >/dev/null || { echo "closure install of bin/lib/hold.sh failed"; exit 1; }
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
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
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; [ "${KEEP_ALERTS:-0}" = 1 ] || : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

write_fly_stub() {
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
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
if [ "\${PROBEMODE:-}" = hang ] && [[ "\$*" == *"-i"* ]] && [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then exec /bin/sleep 30; fi
if [ "\${HOLDMODE:-}" = hang ] && [[ "\$*" == *"issues/"* ]] && [[ "\$*" != *"-i"* ]]; then exec /bin/sleep 30; fi
if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then
  echo "\$*" >> "$T/pr-reads"
  case "\${PRMODE:-none}" in
    open) printf 'HTTP/1.1 200 OK\\n\\n[{"number":9,"html_url":"https://github.com/example-org/project-5/pull/9"}]\\n'; exit 0 ;;
    none) exit 1 ;;
    403) printf 'HTTP/1.1 403 Forbidden\\n\\n{"message":"rate limit"}\\n'; exit 0 ;;
    hang) exec /bin/sleep 30 ;;
    slow) /bin/sleep 2 ;;
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

# A timeout that really times out (the passthrough above ignores the limit).
real_timeout() {
  cat > "$T/fakebin/timeout" <<'TO'
#!/bin/bash
d=$1; shift; "$@" & p=$!
( /bin/sleep "$d"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
wait "$p"; rc=$?; kill "$w" 2>/dev/null; [ "$rc" = 143 ] && rc=124; exit $rc
TO
  chmod +x "$T/fakebin/timeout"
}
passthrough_timeout() { printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"; }

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H"/flags/alerted-pool-pr-* "$T/pr-reads"; do
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
machines() { ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | grep -c . ; }
pr_reads() { count . "$T/pr-reads"; }
alerts() { count 'PR check unreadable\|PR reads' "$H/logs/ALERTS.log"; }

# ── A: unreadable PR reads, six new rows ────────────────────────────────────
reset_state; write_fly_stub; write_gh_stub; passthrough_timeout; queue_n 2001 2006
run_pool PRMODE=none
[ "$(pr_reads)" = 1 ] && ok || bad "A: expected ONE PR read in the tick, got $(pr_reads)"
[ "$(alerts)" = 1 ] && ok || bad "A: expected ONE alert, got $(alerts): $(cat "$H/logs/ALERTS.log")"
[ "$(spawned)" = 3 ] && ok || bad "A: new rows must spawn up to the cap of 3, got $(spawned): $(cat "$H/logs/fly-pool.log")"
grep -q 'new build (attempt 0.*no PR read needed' "$H/logs/fly-pool.log" && ok || bad "A: the new-build decision must be logged"

# ── B: unreadable, rows with a prior spawn record ───────────────────────────
reset_state; queue_n 2001 2003
for n in 2001 2002 2003; do date +%s > "$H/state/pool/project-5/BH-$n.spawns"; done
run_pool PRMODE=none
[ "$(pr_reads)" = 1 ] && ok || bad "B: expected ONE PR read in the tick, got $(pr_reads)"
[ "$(machines)" = 0 ] && ok || bad "B: a row with a prior spawn must not spawn on an unknown PR state, got $(machines)"
[ -f "$H/state/build-queue/project-5/BH-2002.json" ] && ok || bad "B: the rows stay queued"
grep -q 'skipping BH-2002: PR check unreadable' "$H/logs/fly-pool.log" && ok || bad "B: the skip must be logged"

# ── C: a hanging read is cut at the timeout ─────────────────────────────────
reset_state; real_timeout; queue_n 2001 2001
S=$(date +%s)
run_pool PRMODE=hang POOL_GH_READ_TIMEOUT_S=1
E=$(( $(date +%s) - S ))
[ "$E" -lt 20 ] && ok || bad "C: the tick took ${E}s; the hung PR read was not cut"
[ "$(alerts)" = 1 ] && ok || bad "C: a timed-out read must alert once, got $(alerts)"
passthrough_timeout

# ── D: the tick budget ───────────────────────────────────────────────────────
reset_state; queue_n 2001 2008
run_pool PRMODE=slow POOL_TICK_BUDGET_S=3
[ "$(spawned)" -ge 1 ] && [ "$(spawned)" -lt 3 ] && ok || bad "D: the budget must decide one row and stop the walk ($(spawned) of 8 spawned)"
grep -q 'tick budget' "$H/logs/fly-pool.log" && ok || bad "D: the budget stop must be logged"

# ── E: a second tick inside the hour does not alert again ────────────────────
reset_state; queue_n 2001 2002
run_pool PRMODE=none
KEEP_ALERTS=1 run_pool PRMODE=none
[ "$(alerts)" = 1 ] && ok || bad "E: expected ONE alert across two ticks, got $(alerts)"

# ── F: an affirmative 403 is not the no-answer shape: the new row waits ──────
reset_state; queue_n 2001 2003
run_pool PRMODE=403
[ "$(pr_reads)" = 1 ] && ok || bad "F: expected ONE PR read, got $(pr_reads)"
[ "$(spawned)" = 0 ] && ok || bad "F: a 403 must not release a new row, got $(spawned) spawns"
grep -q 'skipping BH-2001: PR check unreadable' "$H/logs/fly-pool.log" && ok || bad "F: the skip must be logged"

# ── G: a CUT repo probe still applies the gates (B1, metered spend) ──────────
# The probe hangs and is cut. Three rows are over the per-key cap and an open PR
# exists: none may spawn. Control: with the probe answering, none spawns either.
reset_state; real_timeout; queue_n 2001 2003
for n in 2001 2002 2003; do printf '%s\n%s\n' "$(date +%s)" "$(date +%s)" > "$H/state/pool/project-5/BH-$n.spawns"; done
run_pool PRMODE=open PROBEMODE=hang POOL_GH_READ_TIMEOUT_S=1
[ "$(spawned)" = 0 ] && ok || bad "G: a cut probe let over-cap rows spawn ($(spawned)): $(cat "$H/logs/fly-pool.log")"
passthrough_timeout

# ── H: only attempt 0 is a new build (I1) ────────────────────────────────────
reset_state; queue_n 2001 2002
jq '.attempt = 1' "$H/state/build-queue/project-5/BH-2001.json" > "$T/q.json" && cp "$T/q.json" "$H/state/build-queue/project-5/BH-2001.json"
run_pool PRMODE=none
grep -q 'skipping BH-2001: PR check unreadable' "$H/logs/fly-pool.log" && ok || bad "H: an attempt-1 row must wait on an unreadable PR read"

# ── I: the hold read is cut too (I2) ─────────────────────────────────────────
reset_state; real_timeout; queue_n 2001 2001
S=$(date +%s)
run_pool HOLDMODE=hang PRMODE=ok POOL_GH_READ_TIMEOUT_S=1
E=$(( $(date +%s) - S ))
[ "$E" -lt 20 ] && ok || bad "I: the tick took ${E}s; the hung hold read was not cut"
passthrough_timeout

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
