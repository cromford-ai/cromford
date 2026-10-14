#!/bin/bash
# tests/lane-fleet-flybin.bh-6697-test.sh — BH-6697: bin/lane-fleet.sh finds
# flyctl under cron's PATH, and the fly-missing alert repeats once per UTC hour
# while flyctl is absent.
#
# WHY. lane-fleet.sh looked flyctl up with `command -v flyctl || command -v fly`.
# Cron's PATH has no /root/.fly/bin, so every hub tick logged `flyctl not found;
# nothing done` and the lane-run fleet started no machine. The fly-missing alert
# fired once per UTC day and nobody acted on it.
#
# WHAT THIS PINS. bin/lib/fly-bin.sh (fly_bin) directly, then the REAL
# bin/lane-fleet.sh tick against a scratch $HARNESS and the real jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs). Every tick runs with a bare PATH
# ($T/tools:/usr/bin:/bin), an empty HOME and LANE_FLEET_FLY unset, unless the
# case says otherwise.
#   B1 HOME/.fly/bin stub, FLY_BIN_DIR unset: fly_bin prints the HOME stub
#   B2 HOME empty, FLY_BIN_DIR stub: fly_bin prints the FLY_BIN_DIR stub
#   B3 HOME empty, FLY_BIN_DIR empty dir: rc 127, nothing printed
#   L1 FLY_BIN_DIR stub only: the tick logs no `flyctl not found`
#   L2 same tick: the stub ran `machine list -a lane-run --json`; `tick wait=none`
#   L3 a PATH stub and a FLY_BIN_DIR stub: only the PATH stub runs
#   L4 LANE_FLEET_FLY and a FLY_BIN_DIR stub: only LANE_FLEET_FLY runs
#   A1 no flyctl at 04:00:30: one ALERTS line, log `flyctl not found (`
#   A2 no flyctl at 04:59:30: still one ALERTS line
#   A3 no flyctl at 05:00:30: two ALERTS lines (it keeps firing)
#   A4 after A3 only the ...-2026100305 fly-missing flag is left
#   A5 a daily kind (stats read failed) at 04:00:30 and 06:00:30: one line
#
# Run from anywhere: tests/lane-fleet-flybin.bh-6697-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/lane-fleet-worker.bh-6126.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or python3 missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" \
  "$T/tools" "$T/home" "$T/empty" "$T/flybin" "$T/pathbin" "$T/seam" "$T/homefx/.fly/bin"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null

# The bare PATH: the tools the tick needs, nothing from /root/.fly/bin.
for c in jq curl flock timeout python3; do
  p=$(command -v "$c") && ln -sf "$p" "$T/tools/$c"
done
BARE="$T/tools:/usr/bin:/bin"
if PATH="$BARE" command -v flyctl >/dev/null 2>&1 || PATH="$BARE" command -v fly >/dev/null 2>&1; then
  bad "a flyctl on the bare PATH would hide the bug ($(PATH="$BARE" command -v flyctl fly | tr '\n' ' '))"
  echo "lane-fleet-flybin.bh-6697: $PASS passed, $FAIL failed"; exit 1
fi

# stub <dir> <argv file> — a flyctl that logs its argv and lists no machine.
stub() {
  cat > "$1/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$2"
case "\$1 \$2" in
  "machine list") echo '[]' ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$1/flyctl"
}
stub "$T/flybin" "$T/argv.flybin"
stub "$T/pathbin" "$T/argv.path"
stub "$T/seam" "$T/argv.seam"
stub "$T/homefx/.fly/bin" "$T/argv.home"

# ============================================================================
echo "B: fly_bin (bin/lib/fly-bin.sh)"
fb() { env -i PATH="$BARE" HOME="$1" ${2:+FLY_BIN_DIR="$2"} \
  bash -c '. "$1" || exit 99; fly_bin' _ "$REPO/bin/lib/fly-bin.sh"; }
out=$(fb "$T/homefx" ""); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$T/homefx/.fly/bin/flyctl" ] && ok "B1 HOME stub, FLY_BIN_DIR unset" || bad "B1 rc=$rc out='$out'"
out=$(fb "$T/home" "$T/flybin"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$T/flybin/flyctl" ] && ok "B2 FLY_BIN_DIR stub is found" || bad "B2 rc=$rc out='$out'"
out=$(fb "$T/home" "$T/empty"); rc=$?
[ "$rc" = 127 ] && [ -z "$out" ] && ok "B3 FLY_BIN_DIR empty: rc 127, nothing printed" || bad "B3 rc=$rc out='$out'"

# ============================================================================
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0
unset LANE_FLEET_FLY FLY_BIN_DIR FLYCTL_INSTALL

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
# fresh <epoch> — a new worker with an empty database, its clock at <epoch>;
# clears the stub argv files, the logs and the alert flags.
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  export LANE_FLEET_NOW=$1
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$1" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { bad "setup: worker $n did not start ($(head -c 400 "$T/w$n.err"))"
    echo "lane-fleet-flybin.bh-6697: $PASS passed, $FAIL failed"; exit 1; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  rm -f "$T"/argv.*
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
}
clock() { export LANE_FLEET_NOW=$1; curl -sS -X PUT "$JOBS_URL/__clock" -d "{\"epoch\":$1}" >/dev/null; }
# tick <FLY_BIN_DIR> [extra PATH dir] — one real tick under the bare PATH.
tick() {
  env -u LANE_FLEET_FLY PATH="${2:+$2:}$BARE" HOME="$T/home" FLY_BIN_DIR="$1" \
    bash "$H/bin/lane-fleet.sh" tick
  TRC=$?
}
nmissing() { grep -c '\[lane-fleet\] flyctl not found' "$H/logs/ALERTS.log"; }

# ============================================================================
echo "L: the tick finds flyctl"
fresh $NOW0
tick "$T/flybin"
[ "$TRC" = 0 ] || bad "L1 tick rc=$TRC"
# The tick must reach the lookup (a log line, and not the not-configured exit).
if [ ! -s "$H/logs/lane-fleet.log" ] || grep -q 'not configured' "$H/logs/lane-fleet.log"; then
  bad "L1 the tick did not reach the flyctl lookup: $(cat "$H/logs/lane-fleet.log")"
elif grep -q 'flyctl not found' "$H/logs/lane-fleet.log"; then
  bad "L1 log: $(cat "$H/logs/lane-fleet.log")"
else ok "L1 no 'flyctl not found' with flyctl only in FLY_BIN_DIR"; fi
grep -qx 'machine list -a lane-run --json' "$T/argv.flybin" 2>/dev/null \
  && ok "L2 the FLY_BIN_DIR stub ran machine list" || bad "L2 argv: $(cat "$T/argv.flybin" 2>/dev/null)"
grep -q 'tick wait=none' "$H/logs/lane-fleet.log" \
  && ok "L2 log has a tick wait=none line" || bad "L2 log: $(cat "$H/logs/lane-fleet.log")"

fresh $NOW0
tick "$T/flybin" "$T/pathbin"
[ -s "$T/argv.path" ] && [ ! -e "$T/argv.flybin" ] \
  && ok "L3 PATH stub wins over FLY_BIN_DIR" || bad "L3 path=$(cat "$T/argv.path" 2>/dev/null) flybin=$(cat "$T/argv.flybin" 2>/dev/null)"

fresh $NOW0
LANE_FLEET_FLY="$T/seam/flyctl" PATH="$BARE" HOME="$T/home" FLY_BIN_DIR="$T/flybin" \
  bash "$H/bin/lane-fleet.sh" tick
[ -s "$T/argv.seam" ] && [ ! -e "$T/argv.flybin" ] \
  && ok "L4 LANE_FLEET_FLY wins over FLY_BIN_DIR" || bad "L4 seam=$(cat "$T/argv.seam" 2>/dev/null) flybin=$(cat "$T/argv.flybin" 2>/dev/null)"

# ============================================================================
echo "A: fly-missing alerts once per UTC hour while it stands"
fresh $NOW0
tick "$T/empty"
[ "$(nmissing)" = 1 ] && ok "A1 04:00:30 one ALERTS line" || bad "A1 alerts: $(cat "$H/logs/ALERTS.log")"
grep -q '\[lane-fleet\] flyctl not found (' "$H/logs/lane-fleet.log" \
  && ok "A1 log line names the places searched" || bad "A1 log: $(cat "$H/logs/lane-fleet.log")"
clock $((NOW0 + 3540)); tick "$T/empty"   # 04:59:30
[ "$(nmissing)" = 1 ] && ok "A2 04:59:30 still one ALERTS line" || bad "A2 alerts: $(cat "$H/logs/ALERTS.log")"
clock $((NOW0 + 3600)); tick "$T/empty"   # 05:00:30
[ "$(nmissing)" = 2 ] && ok "A3 05:00:30 a second ALERTS line" || bad "A3 alerts: $(cat "$H/logs/ALERTS.log")"
flags=$(cd "$H/flags" && ls alerted-lane-fleet-fly-missing-* 2>/dev/null | tr '\n' ' ')
[ "$flags" = "alerted-lane-fleet-fly-missing-2026100305 " ] \
  && ok "A4 one fly-missing flag, the 05 hour" || bad "A4 flags: '$flags'"

fresh $NOW0
export JOBS_URL=http://127.0.0.1:1
tick "$T/flybin"
export LANE_FLEET_NOW=$((NOW0 + 7200)); tick "$T/flybin"   # 06:00:30
n=$(grep -c '\[lane-fleet\] stats read failed' "$H/logs/ALERTS.log")
[ "$n" = 1 ] && ok "A5 a daily kind keeps one line per UTC day" || bad "A5 $n lines: $(cat "$H/logs/ALERTS.log")"

echo
echo "lane-fleet-flybin.bh-6697: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
