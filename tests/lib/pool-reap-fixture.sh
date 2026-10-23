# tests/lib/pool-reap-fixture.sh — a fake HARNESS and a fake flyctl that drive
# the REAL bin/fly-pool.sh reap for one project (project-5). Sourced, never
# executed; tests/*.sh does not glob tests/lib/. The caller has sourced
# tests/lib/scratch.sh (so $T exists) and set DIR to the repo root.
#
# The shape is tests/fly-pool-lane-failure-test.sh's, lifted so the BH-1853
# suites share one copy of it instead of two. The pool-account library is a
# RECORDER: every call the reap makes of it lands in $T/acct-calls, and the
# two answers the lane-hold decision reads are driven from the environment:
#   OTHERS_OK=1  pool_account_others_ok answers "another account can serve"
#   COOLING=1    account_cooling answers "that account is cooling"
# A machine's RESULT is per machine: write_fly_stub takes <mid>=<result> pairs.
# shellcheck shell=bash

prf_setup() {
  NOW=$(date +%s)
  RESET=$((NOW + 3*86400))
  H="$T/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
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
  cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
  printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"
  cat > "$H/bin/lib/pool-account.sh" <<EOF
pool_account_cooldown()  { echo "cooldown \$*" >> "$T/acct-calls"; }
pool_account_unpin()     { echo "unpin \$*" >> "$T/acct-calls"; }
pool_account_prune()     { :; }
pool_account_release()   { :; }
pool_account_armed()     { printf 'test'; return 1; }
pool_account_others_ok() { echo "others_ok \$*" >> "$T/acct-calls"; [ "\${OTHERS_OK:-0}" = 1 ]; }
account_cooling()        { [ "\${COOLING:-0}" = 1 ]; }
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
}

prf_run_pool() { # prf_run_pool [VAR=value...]
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls"; : > "$T/acct-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

write_fly_stub() { # write_fly_stub <mid>=<result-line>...
  local pair arms=""
  for pair in "$@"; do
    arms="$arms  *\"--machine ${pair%%=*} \"*\"head\"*\"RESULT\"*) echo $(printf '%q' "${pair#*=}") ;;
"
  done
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
if [ -n "\${SCALE_FAKE_LATENCY_MS:-}\${SCALE_FAKE_RATE_LIMIT_EVERY:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scale.sh" || exit 1
  scale_fake_gate fly "$T" && exit 1
fi
case "\$*" in
  *"machine status"*) echo "State: started" ;;
$arms  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

prf_reset() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}

machine_json() { # machine_json <mid> <key> <deferrals> [account]
  jq -nc --arg m "$1" --arg k "$2" --arg t "${2#*-}" --argjson d "$3" --arg sct "$((NOW-60))" --arg aa "${4:-}" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-09-23T13:20:00Z",spawn_cap_ts:$sct}
     + (if $aa == "" then {} else {auth_account:$aa} end)' \
    > "$H/state/fly-pool/project-5/$1.json"
  echo "$((NOW-60))" > "$H/state/pool/project-5/$2.spawns"
}
queue_job() { # queue_job <key> — a job waiting in the queue
  jq -nc --arg k "$1" --arg t "${1#*-}" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:00:00Z"}' \
    > "$H/state/build-queue/project-5/$1.json"
}
qdef() { jq -r '.deferrals // "absent"' "$H/state/build-queue/project-5/${1:-BH-1016}.json" 2>/dev/null || echo "no-queue-file"; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null || true; }
destroyed() { grep -E 'machine (destroy|remove)' "$T/fly-calls" 2>/dev/null | grep -c -- "$1" || true; }
pushed_job() { grep -- "--machine $1 " "$T/fly-calls" 2>/dev/null | grep -c 'job.json' || true; }
