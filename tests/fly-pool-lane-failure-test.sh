#!/bin/bash
# tests/fly-pool-lane-failure-test.sh — a stage that failed because the RUNNER
# LANE was out (2026-09-23 pool loop) is not the ticket deferring.
#
# From 13:26Z on 09-23 every pool plan ended the same way: the leased Claude
# account was at its weekly limit and the OpenRouter floor under it answered
# 403 "Key limit exceeded". The reap counted each as the ticket deferring,
# requeued it and spawned again — 398 deferred runs over 71 tickets and ~201
# machines — and the account cooldown never fired, because it grepped the
# machine's failovers.log for vendor words that are never written there.
#
# Pinned here, driven through bin/fly-pool.sh against a fake HARNESS and a fake
# flyctl (the reap reads RESULT through `fly ssh console`):
#   a  RUNNER_EXHAUSTED naming claude: the leased account is cooled until the
#      reset the line carries, its pin is dropped, the ticket is requeued with
#      its deferral count UNCHANGED, the spawn is un-recorded, a project spawn
#      hold is set and nothing is spawned into it the same tick
#   b  class=auth with no exhaustion: a lane failure (requeue unchanged, hold),
#      but no account is cooled — nothing said the account ran out
#   c  exhausted=openrouter only: the Claude account is NOT cooled
#   d  an ordinary deferral still counts, and lane-failure build dirs on disk do
#      not inflate its floor
#   e  the hold stops the spawn loop while it stands and not after
#   f  the machine's failovers.log is relayed into the hub build dir
#   g  with the hold switched off (POOL_LANE_FAIL_HOLD_S=0) the spawn keeps
#      counting against the per-key cap, the one bound left on the respawns
#   h  a machine leased an account while another can serve ships
#      OPENROUTER_FALLBACK=off, so its stage ends RUNNER_EXHAUSTED instead of
#      buying OpenRouter (every attributable OpenRouter dollar 09-21..23 came
#      from pool machines doing exactly that)
#   i  with no other account to serve, the bundle is left alone
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
RESET=$((NOW + 3*86400))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_PROJECT_5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The account library is a RECORDER here: what the reap asks of it is the
# contract under test; tests/pool-account-reset-cooldown-test.sh drives the real
# one. No pool_account_lease, so a spawn ships the bundle as it arrived.
cat > "$H/bin/lib/pool-account.sh" <<EOF
pool_account_cooldown() { echo "cooldown \$*" >> "$T/acct-calls"; }
pool_account_unpin()    { echo "unpin \$*" >> "$T/acct-calls"; }
pool_account_prune()    { :; }
pool_account_release()  { :; }
pool_account_armed()    { printf 'test'; return 1; }
if [ -n "\${LEASE_AS:-}" ]; then
  pool_account_lease()     { printf 'name=%s reason=lease_rank leases=1 five_h=10\n' "\$LEASE_AS"; }
  pool_account_others_ok() { echo "others_ok \$*" >> "$T/acct-calls"; [ "\${OTHERS_OK:-0}" = 1 ]; }
fi
EOF

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

# What the machine's failovers.log holds: the ladder note and the vendor's 403.
printf '%s\n' "2026-09-23 13:26:00Z [project-5] plan claude: class=account-exhausted(quota) token=RUNNER_EXHAUSTED rc=1 acct=default" \
              "2026-09-23 13:27:00Z [project-5] plan openrouter: deepseek/deepseek-v4-flash failed rc=1 — unexpected status 403 Forbidden: Key limit exceeded" \
  > "$T/machine-failovers.log"
FOB64=$(base64 < "$T/machine-failovers.log" | tr -d '\n')

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls"; : > "$T/acct-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"failovers.log"*) printf '%s' "$FOB64" ;;
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
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}

# machine_json <mid> <deferrals> [account]
machine_json() {
  jq -nc --arg m "$1" --arg k "BH-1016" --arg t "1016" --argjson d "$2" --arg sct "$((NOW-60))" --arg aa "${3:-}" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-09-23T13:20:00Z",spawn_cap_ts:$sct}
     + (if $aa == "" then {} else {auth_account:$aa} end)' \
    > "$H/state/fly-pool/project-5/$1.json"
  echo "$((NOW-60))" > "$H/state/pool/project-5/BH-1016.spawns"
}
qdef() { jq -r '.deferrals // "absent"' "$H/state/build-queue/project-5/BH-1016.json" 2>/dev/null || echo "no-queue-file"; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null || true; }
LANE_EX="BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=auth(credential) seen=account-exhausted,auth runner=openrouter rc=1 exhausted=claude resets_at=$RESET"

# ── a: RUNNER_EXHAUSTED naming claude ─────────────────────────────────────
{
  reset_state
  write_fly_stub "$LANE_EX"
  machine_json m-exh 2 max3
  run_pool
  grep -qx "cooldown max3 pool-project-5-BH-1016 $RESET" "$T/acct-calls" \
    && ok || bad "a: the leased account was not cooled until the reset (calls: $(tr '\n' '|' < "$T/acct-calls"))"
  grep -qx "unpin project-5 BH-1016 max3" "$T/acct-calls" \
    && ok || bad "a: the ticket's pin to the exhausted account was not dropped (calls: $(tr '\n' '|' < "$T/acct-calls"))"
  [ "$(qdef)" = 2 ] && ok || bad "a: a lane failure must requeue with deferrals UNCHANGED (2), got $(qdef)"
  [ -s "$H/state/pool/project-5/BH-1016.spawns" ] \
    && bad "a: the lane failure's spawn is still counted against the per-key cap: $(cat "$H/state/pool/project-5/BH-1016.spawns")" || ok
  HF="$H/state/pool/project-5/_spawn-hold"
  if [ -s "$HF" ]; then
    HU=$(cut -d' ' -f1 "$HF")
    [ "$HU" -gt "$NOW" ] && ok || bad "a: the spawn hold is not in the future: $(cat "$HF")"
    grep -q 'BH-1016' "$HF" && ok || bad "a: the hold does not say which ticket set it: $(cat "$HF")"
  else
    bad "a: no project spawn hold was set"
  fi
  [ "$(spawned)" = 0 ] && ok || bad "a: $(spawned) machine(s) were spawned into the exhausted lane in the same tick"
  grep -q 'RUNNER LANE failed' "$H/logs/ALERTS.log" && ok || bad "a: no ALERTS line names the lane failure"
  grep -q 'parked for the blocked-resolver' "$H/logs/ALERTS.log" && bad "a: a lane failure was parked for the resolver" || ok
}

# ── b: class=auth, no exhaustion ──────────────────────────────────────────
{
  reset_state
  write_fly_stub "BUILD_DEFERRED plan session ended RUNNER_ERROR class=auth(credential) seen=auth runner=openrouter rc=1"
  machine_json m-auth 1 max3
  run_pool
  grep -q '^cooldown' "$T/acct-calls" && bad "b: an auth failure cooled the Claude account: $(cat "$T/acct-calls")" || ok
  [ "$(qdef)" = 1 ] && ok || bad "b: class=auth must requeue with deferrals unchanged (1), got $(qdef)"
  [ -s "$H/state/pool/project-5/_spawn-hold" ] && ok || bad "b: class=auth set no spawn hold"
}

# ── c: only the OpenRouter key ran out ────────────────────────────────────
{
  reset_state
  write_fly_stub "BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=account-exhausted(credits) seen=real-failure,account-exhausted runner=openrouter rc=1 exhausted=openrouter"
  machine_json m-or 0 max4
  run_pool
  grep -q '^cooldown' "$T/acct-calls" && bad "c: exhausted=openrouter cooled the Claude account: $(cat "$T/acct-calls")" || ok
  [ "$(qdef)" = 0 ] && ok || bad "c: requeue with deferrals unchanged (0), got $(qdef)"
}

# ── d: an ordinary deferral still counts; lane dirs do not inflate it ─────
{
  reset_state
  for i in 1 2 3; do
    mkdir -p "$H/builds/pool-project-5-BH-1016-2026092313${i}0"
    echo "$LANE_EX" > "$H/builds/pool-project-5-BH-1016-2026092313${i}0/RESULT"
  done
  write_fly_stub "BUILD_DEFERRED wip-limit 2 reached"
  machine_json m-wip 0
  run_pool POOL_SPAWN=0
  [ "$(qdef)" = 1 ] && ok || bad "d: an ordinary deferral after 3 lane failures must be deferral 1, got $(qdef)"
  [ -e "$H/state/pool/project-5/_spawn-hold" ] && bad "d: an ordinary deferral set a spawn hold" || ok
  grep -q '^cooldown' "$T/acct-calls" && bad "d: an ordinary deferral cooled an account" || ok
}

# ── e: the hold stops the spawn loop while it stands, and not after ────────
{
  reset_state
  write_fly_stub ""
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
  echo "$((NOW + 900)) BH-1015: RUNNER_EXHAUSTED" > "$H/state/pool/project-5/_spawn-hold"
  run_pool
  [ "$(spawned)" = 0 ] && ok || bad "e: $(spawned) machine(s) spawned under a standing hold"
  grep -q 'spawn hold' "$H/logs/fly-pool.log" && ok || bad "e: the held tick did not say why it spawned nothing"
  reset_state
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
  echo "$((NOW - 5)) BH-1015: RUNNER_EXHAUSTED" > "$H/state/pool/project-5/_spawn-hold"
  run_pool
  [ "$(spawned)" -ge 1 ] && ok || bad "e: an expired hold still stopped the spawn"
}

# ── f: the machine's failovers.log comes home ─────────────────────────────
{
  reset_state
  write_fly_stub "$LANE_EX"
  machine_json m-relay 0
  run_pool POOL_SPAWN=0
  REL=$(ls -d "$H/builds/pool-project-5-BH-1016-"*/failovers.log 2>/dev/null | head -1)
  if [ -n "$REL" ] && grep -q 'Key limit exceeded' "$REL"; then ok
  else bad "f: the machine's failovers.log was not relayed into the hub build dir (${REL:-none})"; fi
}

# ── g: hold off — the per-key cap is what bounds the respawns ─────────────
{
  reset_state
  write_fly_stub "$LANE_EX"
  machine_json m-nohold 1 max3
  run_pool POOL_SPAWN=0 POOL_LANE_FAIL_HOLD_S=0
  [ -e "$H/state/pool/project-5/_spawn-hold" ] && bad "g: POOL_LANE_FAIL_HOLD_S=0 still set a hold" || ok
  [ -s "$H/state/pool/project-5/BH-1016.spawns" ] && ok \
    || bad "g: with the hold off the spawn must keep counting against the per-key cap"
  [ "$(qdef)" = 1 ] && ok || bad "g: deferrals must still be unchanged (1), got $(qdef)"
}

# ── h/i: a leased machine is told OpenRouter is off while another account can serve
# (the operator 2026-09-24: "No need to use OpenRouter if the Claude OAuth is working").
# The bundle is read back out of the console command that pushed it.
pushed_global() {
  local tok
  grep 'harness-env/global.env' "$T/fly-calls" 2>/dev/null | grep -oE '[A-Za-z0-9+/]{16,}={0,2}' | while read -r tok; do
    printf '%s' "$tok" | base64 -d 2>/dev/null
  done
}
{
  reset_state
  write_fly_stub ""
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
  run_pool LEASE_AS=max3 OTHERS_OK=1
  [ "$(spawned)" -ge 1 ] && ok || bad "h: no machine was spawned"
  grep -qx 'others_ok max3' "$T/acct-calls" && ok || bad "h: the spawn never asked whether another account could serve ($(tr '\n' '|' < "$T/acct-calls"))"
  [ "$(pushed_global | grep -c '^OPENROUTER_FALLBACK=off$')" = 1 ] && ok \
    || bad "h: the machine's bundle does not carry exactly one OPENROUTER_FALLBACK=off: $(pushed_global | grep OPENROUTER || echo none)"
  reset_state
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
  run_pool LEASE_AS=max3 OTHERS_OK=0
  grep -q '^OPENROUTER_FALLBACK=' <<<"$(pushed_global)" && bad "i: OpenRouter was switched off with no other account to serve" || ok
}

echo "fly-pool-lane-failure: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
