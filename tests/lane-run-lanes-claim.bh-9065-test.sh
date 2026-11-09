#!/bin/bash
# tests/lane-run-lanes-claim.bh-9065-test.sh — BH-9065 C4: the claim side of
# lane machines. bin/lane-fleet.sh starts a lane machine with
# -e LANE_RUN_LANES=<lane>; bin/lane-run-worker.sh on it claims only that lane.
# Any other fleet machine (LANE_RUN_LANES unset, no --box) claims with
# exclude_lanes = the lanes whose catalog/lanes.d/<lane>.json declares a valid
# `machine`, so a fleet machine never takes a lane machine's run.
#
# A real bin/lane-run-worker.sh --once against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs). No Fly call, no vendor call.
#
#   L1  LANE_RUN_LANES=<declared>: runs that lane's row only; the other stays
#       queued; the claim body carries lanes:[<lane>]
#   L2  LANE_RUN_LANES with an invalid name: no claim, one log line, rc 0
#   L3  LANE_RUN_LANES="a,b c": the claim carries all three names
#   X1  a group machine (LANE_RUN_GROUP): the declared lane stays queued, the
#       undeclared lane runs; the claim carries exclude_lanes
#   X2  a default machine: the same
#   X3  a lane whose machine key is invalid is not excluded (lane-fleet gives it
#       the fleet size, so a fleet machine must run it)
#   X4  a lane machine never sends exclude_lanes
#
# Run from anywhere: tests/lane-run-lanes-claim.bh-9065-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/lane-fleet-worker.bh-6126.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
"$REPO/bin/lanes-build.sh" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

U="$$"
LD="cpuheavy-$U"; LU="cpulight-$U"; LX="cpubad-$U"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog/lanes.d"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$H"/bin/*.sh "$H"/bin/lib/*.sh 2>/dev/null
jq -n --arg i "$LD" '{id:$i, machine:{cpu:"performance", size:"performance-4x"}}' > "$H/catalog/lanes.d/$LD.json"
jq -n --arg i "$LU" '{id:$i}' > "$H/catalog/lanes.d/$LU.json"
jq -n --arg i "$LX" '{id:$i, machine:{cpu:"performance", size:"shared-cpu-2x"}}' > "$H/catalog/lanes.d/$LX.json"
for p in project-6-os project-3; do printf '%s o/%s - - 2 box-%s 192.0.2.1\n' "$p" "$p" "$p"; done > "$H/fleet.conf"
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
echo "\${@: -1}" >> "$T/runs.txt"
exit 0
EOF
chmod +x "$H/bin/fake-lane.sh"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub FLEET_CONF="$H/fleet.conf"
export GH_TOKEN=tok-fixture-default JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
NOW0=1791000030
export LANE_GATE_NOW=$NOW0 LANE_RUN_NOW=$NOW0

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  NOW=$1
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$1" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
  WLOGF="$T/w$n.log"
  : > "$H/logs/lane-run-worker.log"
}
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
q() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES (?,?,'[\"bin/fake-lane.sh\"]',?,'queued')" \
  "$1" "$2" "$(iso $((NOW - $3)))" >/dev/null; }
# work [VAR=value ...] — one real worker pass (--once drains the queue). The
# claim bodies are traced through a curl wrapper first on PATH.
mkdir -p "$T/pbin"
cat > "$T/pbin/curl" <<EOF
#!/bin/bash
prev=""; for a in "\$@"; do case "\$prev" in -d|--data|--data-raw|--data-binary) b="\$a"; case "\$b" in @*) b=\$(cat "\${b#@}" 2>/dev/null) ;; esac
    case "\$b" in *'"machine"'*) printf '%s\n' "\$b" >> "$T/claims.txt" ;; esac ;; esac; prev="\$a"; done
exec $(command -v curl) "\$@"
EOF
chmod +x "$T/pbin/curl"
work() { : > "$T/runs.txt"; : > "$T/claims.txt"
  env PATH="$T/pbin:$PATH" REPOS_ROOT="$T/norepos" "$@" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/wk.out" 2>&1; WRC=$?; }
qlanes() { sql "SELECT lane FROM lane_runs WHERE status='queued' ORDER BY lane" | jq -r '[.rows[].lane] | join(" ")'; }
dlanes() { sql "SELECT lane FROM lane_runs WHERE status IN ('done','claimed') ORDER BY lane" | jq -r '[.rows[].lane] | join(" ")'; }
claim1() { grep '"machine":"m1"' "$T/claims.txt" | head -1; }

fresh $NOW0; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T"/w*.err)"; exit 1; }

# ============================================================================
echo "L1: LANE_RUN_LANES=<declared lane> claims that lane only"
q "$LU" project-3 90; q "$LD" project-3 30; work LANE_RUN_LANES="$LD"
[ "$WRC" = 0 ] && ok "L1 rc 0" || bad "L1 rc $WRC: $(cat "$T/wk.out")"
[ "$(dlanes)" = "$LD" ] && [ "$(qlanes)" = "$LU" ] && ok "L1 ran $LD only; $LU (older) stays queued" \
  || bad "L1 done: $(dlanes) queued: $(qlanes) log: $(cat "$H/logs/lane-run-worker.log")"
[ "$(claim1 | jq -c '.lanes')" = "[\"$LD\"]" ] && ok "L1 the claim carries lanes:[$LD]" || bad "L1 claim: $(cat "$T/claims.txt")"
claim1 | jq -e 'has("exclude_lanes") | not' >/dev/null && ok "X4 a lane machine sends no exclude_lanes" || bad "X4 claim: $(claim1)"

echo "L2: an invalid LANE_RUN_LANES -> no claim, one log line"
fresh $NOW0; q "$LU" project-3 90; work LANE_RUN_LANES="bad/name"
[ "$WRC" = 0 ] && [ ! -s "$T/runs.txt" ] && ok "L2 rc 0, nothing ran" || bad "L2 rc $WRC runs: $(cat "$T/runs.txt")"
grep -q 'POST /api/lane-runs/claim' "$WLOGF" && bad "L2 a claim was sent" || ok "L2 no claim sent"
[ "$(grep -c "LANE_RUN_LANES='bad/name' is not valid" "$H/logs/lane-run-worker.log")" = 1 ] && ok "L2 one log line" \
  || bad "L2 log: $(cat "$H/logs/lane-run-worker.log")"

echo "L3: a list of names"
fresh $NOW0; q "$LU" project-3 90; work LANE_RUN_LANES="$LD,$LU x$U"
[ "$(claim1 | jq -c '.lanes')" = "[\"$LD\",\"$LU\",\"x$U\"]" ] && ok "L3 lanes carries the three names" || bad "L3 claim: $(cat "$T/claims.txt")"
[ "$(dlanes)" = "$LU" ] && ok "L3 a listed lane runs" || bad "L3 done: $(dlanes)"

echo "X1: a group machine never claims a declared lane"
fresh $NOW0
setting lane_fleet.group.project-6 '{"app":"lane-run-mk","vm_size":"shared-cpu-2x","vm_memory":4096,"max_machines":4,"projects":["project-6-os"]}'
q "$LD" project-6-os 90; q "$LU" project-6-os 30; work LANE_RUN_GROUP=project-6
[ "$(dlanes)" = "$LU" ] && [ "$(qlanes)" = "$LD" ] && ok "X1 ran $LU; $LD (older) stays queued" \
  || bad "X1 done: $(dlanes) queued: $(qlanes) log: $(cat "$H/logs/lane-run-worker.log")"
[ "$(claim1 | jq -c '.exclude_lanes')" = "[\"$LD\"]" ] && ok "X1 the claim carries exclude_lanes:[$LD]" || bad "X1 claim: $(cat "$T/claims.txt")"

echo "X2: a default machine never claims a declared lane"
fresh $NOW0; q "$LD" project-3 90; q "$LU" project-3 30; work
[ "$(dlanes)" = "$LU" ] && [ "$(qlanes)" = "$LD" ] && ok "X2 ran $LU; $LD stays queued" \
  || bad "X2 done: $(dlanes) queued: $(qlanes) log: $(cat "$H/logs/lane-run-worker.log")"

echo "X3: a lane with an invalid machine key is not excluded"
fresh $NOW0; q "$LX" project-3 90; work
[ "$(dlanes)" = "$LX" ] && ok "X3 $LX runs on a fleet machine" || bad "X3 done: $(dlanes) queued: $(qlanes)"

echo
echo "lane-run-lanes-claim.bh-9065: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
