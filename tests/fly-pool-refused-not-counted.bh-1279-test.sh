#!/bin/bash
# tests/fly-pool-refused-not-counted.bh-1279-test.sh — a claim REFUSED by a
# phase-6 concurrency rule (or a pause) never ran, so it must not count
# against POOL_SPAWN_CAP_PER_KEY. Before this fix spawn_one recorded every
# entry unconditionally (BH-1075's own rule) and nothing ever un-recorded a
# refusal, so a fleet-wide `repo *  build` or `box * build` rule refusing
# every claim converted into per-key POOL_DEFER_TO_HUMAN parking within two
# ticks — the second bug on BH-1279 (17 keys parked twice on 2026-09-21).
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

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
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
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh"
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
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

# Fly stub: supports reap reads, machine run, and a no-op ssh console / sftp.
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
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

write_gh_stub() {
  local head_sha="${1:-}" pr_count="${2:-0}" issue_state="${3:-open}"
  cat > "$T/fakebin/gh" <<GH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in issue) echo "\$*" >> "${T}/gh-sink.txt"; exit 0 ;; esac
done
if [[ "\$*" == *"issues/"*"/comments"* ]] && [[ "\$*" == *"body=@"* ]]; then
  echo '{"id":1}'
  exit 0
fi
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/1016"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"$issue_state","labels":[{"name":"ai-build"}],"title":"","body":""}'
  exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'
    exit 0
  fi
  if [[ "\$*" == *"git/ref/heads/ticket/bh-1016"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    [ -n "$head_sha" ] && echo "{\"object\":{\"sha\":\"$head_sha\"}}" || echo '{}'
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    if [ "$pr_count" = 0 ]; then echo '[]'; else
      echo '[{"number":55,"state":"open","html_url":"https://github.com/example-org/project-5/pull/55","head":{"ref":"ticket/bh-1016","repo":{"full_name":"example-org/project-5"}}}]'
    fi
    exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'
  exit 0
fi
exit 0
GH
  chmod +x "$T/fakebin/gh"
}

reset_state() { # reset_state [builds]
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  if [ "${1:-}" = builds ]; then
    for p in "$H/builds"/*; do [ -e "$p" ] && scratch_rm "$p"; done
  fi
  return 0
}

queue_bh1016() {
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
}

# ── a: a fresh spawn records its OWN timestamp on the machine json ─────────
# spawn_cap_ts must be the exact line pool_spawn_cap_record appended, so the
# reap can later remove exactly it and nothing else.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0
  queue_bh1016
  run_pool
  MJ=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | head -1)
  [ -n "$MJ" ] && ok "a: a machine was spawned" || bad "a: no machine json found"
  SCT=$(jq -r '.spawn_cap_ts // ""' "$MJ" 2>/dev/null)
  [ -n "$SCT" ] && ok "a: spawn_cap_ts is present on the machine json" \
    || bad "a: spawn_cap_ts missing from machine json: $(cat "$MJ" 2>/dev/null)"
  SPAWNS=$(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null)
  [ "$SPAWNS" = "$SCT" ] && ok "a: spawn_cap_ts matches the .spawns log entry" \
    || bad "a: spawn_cap_ts '$SCT' does not match .spawns log '$SPAWNS'"
}

# ── b: a REFUSED reap un-records exactly its own spawn, nothing else ───────
{
  reset_state
  write_fly_stub "BUILD_DEFERRED REFUSED repo :: repo max 1 already running"
  write_gh_stub "" 0
  queue_bh1016
  # Two prior (real) spawns already on the ledger, plus the one THIS machine
  # recorded when it was spawned (SCT). The reap must remove SCT and leave
  # the other two untouched.
  PRIOR1=$((NOW-7200)); PRIOR2=$((NOW-3600))
  SCT=$((NOW-60))
  { echo "$PRIOR1"; echo "$PRIOR2"; echo "$SCT"; } > "$H/state/pool/project-5/BH-1016.spawns"
  jq -nc --arg m "m-ref279" --arg k "BH-1016" --arg t "1016" --arg sct "$SCT" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-21T20:40:00Z",spawn_cap_ts:$sct}' \
    > "$H/state/fly-pool/project-5/m-ref279.json"
  # POOL_SPAWN=0 isolates the REAP: without it, the two remaining .spawns
  # entries plus a fresh same-tick respawn of the just-requeued ticket would
  # land exactly on the default cap of 2 and this case would assert nothing
  # about the un-record — it would assert the (unrelated, already-covered-by
  # BH-1075) cap-parks-the-row behaviour instead.
  run_pool POOL_SPAWN=0
  N=$(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 2 ] && ok "b: exactly one entry (the refused spawn's own) was removed" \
    || bad "b: expected 2 remaining .spawns entries, got $N: $(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null)"
  grep -qx "$SCT" "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null \
    && bad "b: the refused spawn's own timestamp is still on the ledger" \
    || ok "b: the refused spawn's own timestamp was removed"
  grep -qx "$PRIOR1" "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null \
    && grep -qx "$PRIOR2" "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null \
    && ok "b: the two earlier real spawns are untouched" \
    || bad "b: an earlier real spawn was wrongly removed: $(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null)"
  # The refusal still behaves exactly as before otherwise: requeued, not lost.
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "b: the refused ticket is still requeued" || bad "b: the refused ticket was not requeued"
  grep -q 'DEFERRED BH-1016.*requeued' "$H/logs/fly-pool.log" \
    && ok "b: the requeue is still logged" || bad "b: requeue log line missing"
}

# ── c: an ordinary (non-REFUSED) deferral still counts — the machine ran ───
{
  reset_state builds
  write_fly_stub "BUILD_DEFERRED wip-limit 2 reached"
  write_gh_stub "" 0
  queue_bh1016
  SCT=$((NOW-60))
  echo "$SCT" > "$H/state/pool/project-5/BH-1016.spawns"
  jq -nc --arg m "m-wip279" --arg k "BH-1016" --arg t "1016" --arg sct "$SCT" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-21T20:40:00Z",spawn_cap_ts:$sct}' \
    > "$H/state/fly-pool/project-5/m-wip279.json"
  run_pool POOL_SPAWN=0
  N=$(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "c: a non-REFUSED deferral still counts against the cap" \
    || bad "c: expected the wip-limit deferral's spawn to still be counted, got $N entries"
}

# ── mutation: a machine json with no spawn_cap_ts un-records nothing ───────
# (an old machine json from before this change, or a rebase) — must never
# error and must never touch an unrelated timestamp.
{
  reset_state
  write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running"
  write_gh_stub "" 0
  queue_bh1016
  echo "$((NOW-60))" > "$H/state/pool/project-5/BH-1016.spawns"
  jq -nc --arg m "m-nosct279" --arg k "BH-1016" --arg t "1016" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-21T20:40:00Z"}' \
    > "$H/state/fly-pool/project-5/m-nosct279.json"
  run_pool POOL_SPAWN=0
  N=$(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "mutation: no spawn_cap_ts on the machine json un-records nothing" \
    || bad "mutation: expected the untouched entry to remain, got $N"
}

echo "fly-pool-refused-not-counted: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
