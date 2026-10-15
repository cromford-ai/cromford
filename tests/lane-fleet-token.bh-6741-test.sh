#!/bin/bash
# tests/lane-fleet-token.bh-6741-test.sh — BH-6741: bin/lane-fleet.sh loads the
# Fly token from env/fly.env, as bin/fly-pool.sh does, and never falls back to
# the interactive ~/.fly session.
#
# WHY. After BH-6697 put flyctl on the lane fleet's PATH, the next hub tick
# failed one step later: "tick read failed: fly-list (Error: your flyctl
# session has expired ...)". lane-fleet.sh never loaded env/fly.env, so flyctl
# had no token and read the expired login in ~/.fly/config.yml. The lane fleet
# started 0 machines.
#
# WHAT THIS PINS. The REAL bin/lane-fleet.sh tick against a scratch $HARNESS and
# the real jobs worker (tests/lib/lane-fleet-worker.bh-6126.mjs). The stub
# flyctl fails like the hub did unless FLY_ACCESS_TOKEN or FLY_API_TOKEN is set,
# and records the token it saw.
#   K1 env/fly.env with the org FLY_API_TOKEN: flyctl gets it as
#      FLY_ACCESS_TOKEN; the tick reads the machine list (tick wait=none)
#   K2 FLY_API_TOKEN_LANE_RUN wins over the org token
#   K3 no token: flyctl is never run, one "Fly token missing for lane-run"
#      ALERTS line, no start or stop; a second tick in the hour adds no line
#   K4 a rejected token: one "Fly token rejected for lane-run" ALERTS line that
#      names flyctl's error, not the generic fly-list read failure
#
# Run from anywhere: tests/lane-fleet-token.bh-6741-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/lane-fleet-worker.bh-6126.mjs"
# The worker imports the generated catalogs; a fresh tree has neither.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or python3 missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$T/fly" "$T/home/.fly"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
# An expired interactive login, as on the hub. A tick that reads it is the bug.
printf 'access_token: fixture-expired-session\n' > "$T/home/.fly/config.yml"

# The stub: no token in its env = the hub's error. It records the token it saw.
cat > "$T/fly/flyctl" <<EOF
#!/bin/bash
echo "\$*|\${FLY_ACCESS_TOKEN:-}|\${FLY_API_TOKEN:-}" >> "$T/argv"
if [ -z "\${FLY_ACCESS_TOKEN:-}\${FLY_API_TOKEN:-}" ]; then
  echo "Error: your flyctl session has expired. Run \\\`fly auth login\\\` to log in again" >&2; exit 1
fi
if [ -f "$T/reject" ]; then echo "Error: unauthorized: token is not valid (401)" >&2; exit 1; fi
case "\$1 \$2" in
  "machine list") echo '[]' ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/fly/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub HARNESS_ENV_DIR="$H/env"
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/fly/flyctl"
unset FLY_ACCESS_TOKEN FLY_API_TOKEN FLY_API_TOKEN_LANE_RUN
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0
PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
# fresh — a new worker with an empty database; clears argv, logs and flags.
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  export LANE_FLEET_NOW=$NOW0
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$NOW0" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done   # determinism: ok waits for the worker to print its port
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { bad "setup: worker $n did not start ($(head -c 400 "$T/w$n.err"))"
    echo "lane-fleet-token.bh-6741: $PASS passed, $FAIL failed"; exit 1; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  rm -f "$T/argv" "$T/reject" "$H/env/fly.env"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
}
tick() { HOME="$T/home" bash "$H/bin/lane-fleet.sh" tick; TRC=$?; }

echo "K1: the org token from env/fly.env"
fresh
printf 'FLY_API_TOKEN=fake-org-token\n' > "$H/env/fly.env"
tick
[ "$TRC" = 0 ] || bad "K1 tick rc=$TRC"
grep -q '^machine list -a lane-run --json|fake-org-token|' "$T/argv" 2>/dev/null \
  && ok "K1 flyctl ran with FLY_ACCESS_TOKEN=the org token" || bad "K1 argv: $(cat "$T/argv" 2>/dev/null)"
grep -q 'tick wait=none' "$H/logs/lane-fleet.log" && ! grep -q 'session has expired' "$H/logs/lane-fleet.log" \
  && ok "K1 the tick read the machine list" || bad "K1 log: $(cat "$H/logs/lane-fleet.log")"

echo "K2: the lane-run token wins"
fresh
printf 'FLY_API_TOKEN=fake-org-token\nFLY_API_TOKEN_LANE_RUN=fake-lane-token\n' > "$H/env/fly.env"
tick
grep -q '^machine list -a lane-run --json|fake-lane-token|' "$T/argv" 2>/dev/null \
  && ok "K2 flyctl ran with FLY_ACCESS_TOKEN from FLY_API_TOKEN_LANE_RUN" || bad "K2 argv: $(cat "$T/argv" 2>/dev/null)"

echo "K3: no token"
fresh
tick
[ "$TRC" = 0 ] || bad "K3 tick rc=$TRC"
[ ! -e "$T/argv" ] && ok "K3 flyctl never ran (no fallback to the ~/.fly session)" || bad "K3 flyctl ran: $(cat "$T/argv")"
[ "$(grep -c '\[lane-fleet\] Fly token missing for lane-run' "$H/logs/ALERTS.log")" = 1 ] \
  && ok "K3 one 'Fly token missing for lane-run' ALERTS line" || bad "K3 alerts: $(cat "$H/logs/ALERTS.log")"
grep -q 'Fly token missing' "$H/logs/lane-fleet.log" && ! grep -qE 'action=start|action=stop' "$H/logs/lane-fleet.log" \
  && ok "K3 the log names the cause, no start or stop" || bad "K3 log: $(cat "$H/logs/lane-fleet.log")"
export LANE_FLEET_NOW=$((NOW0 + 600)); tick; export LANE_FLEET_NOW=$NOW0
[ "$(grep -c 'Fly token missing' "$H/logs/ALERTS.log")" = 1 ] \
  && ok "K3 a second tick in the hour adds no ALERTS line" || bad "K3 alerts after 2 ticks: $(cat "$H/logs/ALERTS.log")"

echo "K4: a rejected token"
fresh
printf 'FLY_API_TOKEN=fake-org-token\n' > "$H/env/fly.env"; : > "$T/reject"
tick
[ "$(grep -c '\[lane-fleet\] Fly token rejected for lane-run' "$H/logs/ALERTS.log")" = 1 ] \
  && grep -q 'unauthorized' "$H/logs/ALERTS.log" \
  && ok "K4 one 'Fly token rejected for lane-run' line that names flyctl's error" || bad "K4 alerts: $(cat "$H/logs/ALERTS.log")"
! grep -q 'fly-list read failed' "$H/logs/ALERTS.log" \
  && ok "K4 not the generic fly-list read failure" || bad "K4 alerts: $(cat "$H/logs/ALERTS.log")"

echo "lane-fleet-token.bh-6741: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
