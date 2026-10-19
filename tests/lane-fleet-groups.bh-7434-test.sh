#!/bin/bash
# tests/lane-fleet-groups.bh-7434-test.sh — BH-7434: lane-run fleet groups.
# A settings row lane_fleet.group.<name> = {app, vm_size, vm_memory,
# max_machines, projects} makes bin/lane-fleet.sh run one more scale pass,
# against the group's own Fly app with the group's size; a machine of the group
# (LANE_RUN_GROUP=<name>) claims only the group's projects, and the default
# `lane-run` fleet skips them until a row waited past lane_run.group_fallback_s.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs, worker clock pinned), with a stub
# flyctl on LANE_FLEET_FLY that is app-aware (a listing file per app, `apps
# create`, `secrets list`) and logs its argv. No real Fly call.
#
#   N1  no group row: one pass on lane-run exactly as today (no fleet/app query)
#   N2  two group rows: three passes, each on its own app with its own size,
#       LANE_RUN_GROUP on a group's machine, rows recorded with their app
#   N3  group max_machines: the group at its ceiling starts nothing; others do
#   N4  a missing group app: apps create in FLY_ORG, then no start and one
#       ALERTS line until the app has its secrets; the default pass still runs
#   N5  no FLY_ORG: no create, one ALERTS line
#   N6  a group row deleted while its machine runs: the machine's row stays
#       started (no pass reconciles it), one orphan ALERTS line per UTC day
#   N7  the proposed rows (max_machines set, warm_floor 0) are valid groups
#   F1  fallback: a grouped row past lane_run.group_fallback_s -> one ALERTS
#       line per UTC day, and the default pass counts and starts for it
#   F2  group_fallback_s 0: no fallback alert, the default pass does not count it
#   W1  LANE_RUN_GROUP=project-6: runs project-6-os rows only
#   W2  LANE_RUN_GROUP with no valid row: no claim at all, one log line; a
#       long-running worker exits after LW_NOGROUP_POLLS polls (machine stops);
#       a settings outage does not count toward that
#   W3  no LANE_RUN_GROUP: the default machine never runs a grouped row
#   R1  fly-idle-reaper's signal_for: lane-run-<x> apps are source lane-run
#
# Run from anywhere: tests/lane-fleet-groups.bh-7434-test.sh (exit 0 = pass)
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

H="$T/h"; FX="$T/fx"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$FX"
for L in bin/lane-fleet.sh bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
# The scratch copies run on the bash first on PATH (a macOS /bin/bash is 3.2,
# too old for the libs); on Linux that is /bin/bash, so nothing changes there.
sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$H"/bin/*.sh "$H"/bin/lib/*.sh 2>/dev/null

# The stub flyctl. fx/list-<app>.json is that app's listing; no file = the app
# does not exist. fx/secrets-<app>.json is its secrets list. Each `machine run`
# prints its own id, <app minus lane-run>run0<n>.
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
app=""; prev=""
for a in "\$@"; do case "\$prev" in -a|--app) app="\$a" ;; esac; prev="\$a"; done
case "\$1 \$2" in
  "machine list") [ -f "$FX/list-\$app.json" ] || { echo "Error: Could not find App \"\$app\"" >&2; exit 1; }
                  cat "$FX/list-\$app.json" ;;
  "secrets list") [ -f "$FX/list-\$app.json" ] || { echo "Error: Could not find App \"\$app\"" >&2; exit 1; }
                  cat "$FX/secrets-\$app.json" 2>/dev/null || echo '[]' ;;
  "apps create") echo '[]' > "$FX/list-\$3.json"; echo "New app created: \$3" ;;
  "machine run") n=\$(( \$(cat "$FX/run.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$FX/run.n"
                 s=\${app#lane-run}; s=\${s#-}; printf 'Machine ID: %sfixrun0%s\nState: created\n' "\${s:-dflt}" "\$n" ;;
  "machine start"|"machine stop") echo "fixture ok" ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub FLEET_CONF="$H/fleet.conf"
export GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl"
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0 LANE_RUN_NOW=$NOW0
MK='{"app":"lane-run-mk","vm_size":"performance-4x","vm_memory":8192,"max_machines":4,"projects":["project-6-os"]}'
TS='{"app":"lane-run-ts","vm_size":"shared-cpu-4x","vm_memory":4096,"max_machines":2,"projects":["project-5"]}'
SECRETS='[{"Name":"HARNESS_SECRET"},{"Name":"JOBS_URL"},{"Name":"GH_APP_ID"}]'

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  NOW=$1; export LANE_FLEET_NOW=$1
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$1" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w$n.err")"; exit 1; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  WLOGF="$T/w$n.log"
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list-lane-run.json"
  printf 'FLY_API_TOKEN=fixture-fly-token\nFLY_ORG=fixture-org\n' > "$H/env/fly.env"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; : > "$H/logs/lane-run-worker.log"; rm -f "$H/flags/"alerted-lane-fleet-*
  [ ! -e "$H/state/lane-fleet" ] || scratch_rm "$H/state/lane-fleet" || exit 1
  setting lane_fleet.warm_floor 0
}
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
# groups_ready — both group apps exist with their secrets.
groups_ready() { local a; for a in lane-run-mk lane-run-ts; do echo '[]' > "$FX/list-$a.json"; echo "$SECRETS" > "$FX/secrets-$a.json"; done; }
# q <lane> <project> <seconds ago> — one queued row.
q() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES (?,?,'[\"bin/fake-lane.sh\"]',?,'queued')" \
  "$1" "$2" "$(iso $((NOW - $3)))" >/dev/null; }
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; }
runs_for() { grep -E -- "machine run .* --app $1 " "$FX/fly.argv"; }
nrun() { runs_for "$1" | grep -c .; }
napp() { sql "SELECT COUNT(*) AS n FROM lane_machines WHERE app=? AND state='starting'" "$1" | jq '.rows[0].n'; }

# ============================================================================
echo "N1: no group row -> one pass on lane-run, as today"
fresh $NOW0; q demo project-6-os 120; q demo project-3 120; tick
[ "$TRC" = 0 ] && ok "N1 tick rc 0" || bad "N1 rc $TRC"
[ "$(grep -cvE -- '-a lane-run( |$)|--app lane-run ' "$FX/fly.argv")" = 0 ] && ok "N1 every flyctl call is on lane-run" || bad "N1 argv: $(cat "$FX/fly.argv")"
[ "$(nrun lane-run)" = 1 ] && runs_for lane-run | grep -q -- '--vm-size shared-cpu-2x --vm-memory 2048 -e LANE_RUN=1$' \
  && ok "N1 one machine run, today's size and env (no LANE_RUN_GROUP)" || bad "N1 run: $(runs_for lane-run)"
grep -q '^GET /api/lane-runs/stats?run_p50=1 200$' "$WLOGF" && ok "N1 stats read has no fleet query" || bad "N1 reads: $(cat "$WLOGF")"
grep -q '^GET /api/lane-fleet/machines?app=lane-run 200$' "$WLOGF" && ok "N1 machines read is scoped to app lane-run (#7447 F1)" || bad "N1 reads: $(cat "$WLOGF")"
[ "$(grep -c 'tick wait=' "$H/logs/lane-fleet.log")" = 1 ] && grep -q '\[lane-fleet\] tick wait=120 live=0 inflight=0 floor=0 max=none action=start dfltfixrun01 queue-wait' "$H/logs/lane-fleet.log" \
  && ok "N1 one tick line, today's shape" || bad "N1 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(sql "SELECT app FROM lane_machines" | jq -r '.rows[0].app')" = lane-run ] && ok "N1 the row is app lane-run" || bad "N1 app: $(sql 'SELECT * FROM lane_machines')"

echo "N2: two group rows -> three passes, each on its own app with its own size"
fresh $NOW0; groups_ready
setting lane_fleet.group.project-6 "$MK"; setting lane_fleet.group.project-5 "$TS"
q demo project-6-os 120; q demo2 project-6-os 120; q demo project-5 120; q demo project-3 120; tick
[ "$TRC" = 0 ] && ok "N2 tick rc 0" || bad "N2 rc $TRC"
[ "$(nrun lane-run-mk)" = 1 ] && runs_for lane-run-mk | grep -q -- '--vm-size performance-4x --vm-memory 8192 -e LANE_RUN=1 -e LANE_RUN_GROUP=project-6$' \
  && ok "N2 project-6: one run on lane-run-mk, performance-4x 8192, LANE_RUN_GROUP=project-6" || bad "N2 mk: $(cat "$FX/fly.argv")"
[ "$(nrun lane-run-ts)" = 1 ] && runs_for lane-run-ts | grep -q -- '--vm-size shared-cpu-4x --vm-memory 4096 -e LANE_RUN=1 -e LANE_RUN_GROUP=project-5$' \
  && ok "N2 project-5: one run on lane-run-ts, shared-cpu-4x 4096" || bad "N2 ts: $(cat "$FX/fly.argv")"
[ "$(nrun lane-run)" = 1 ] && runs_for lane-run | grep -q -- '--vm-size shared-cpu-2x --vm-memory 2048 -e LANE_RUN=1$' \
  && ok "N2 default: one run on lane-run, today's size" || bad "N2 default: $(cat "$FX/fly.argv")"
for f in default project-6 project-5; do
  grep -q "^GET /api/lane-runs/stats?run_p50=1&fleet=$f 200$" "$WLOGF" && ok "N2 stats read fleet=$f" || bad "N2 stats $f: $(grep stats "$WLOGF")"
done
for a in lane-run lane-run-mk lane-run-ts; do
  grep -q "^GET /api/lane-fleet/machines?app=$a 200$" "$WLOGF" && ok "N2 machines read app=$a" || bad "N2 machines $a: $(grep machines "$WLOGF")"
  [ "$(napp $a)" = 1 ] && ok "N2 one starting row with app $a" || bad "N2 rows $a: $(sql 'SELECT machine_id, app FROM lane_machines')"
done
grep -q '\[lane-fleet:project-6\] tick wait=120 live=0 inflight=0 floor=0 max=4 action=start mkfixrun0' "$H/logs/lane-fleet.log" \
  && grep -q '\[lane-fleet\] tick wait=120 live=0 inflight=0 floor=0 max=none action=start dfltfixrun0' "$H/logs/lane-fleet.log" \
  && ok "N2 one tick line per fleet, the group's tagged" || bad "N2 log: $(cat "$H/logs/lane-fleet.log")"
# The default pass counts only project-3: one queued run, work 0 -> exactly one start.
grep -q '\[lane-fleet\] tick wait=120 .* work=0s' "$H/logs/lane-fleet.log" && ok "N2 default pass: the grouped rows are not its work" || bad "N2 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(grep -c 'apps create' "$FX/fly.argv")" = 0 ] && ok "N2 existing apps are not created" || bad "N2 argv: $(cat "$FX/fly.argv")"

echo "N3: the group at its max_machines starts nothing; the others still do"
fresh $NOW0; groups_ready
setting lane_fleet.group.project-6 "$(jq -c '.max_machines = 1' <<<"$MK")"
api POST /api/lane-fleet/machines "$(jq -nc --arg a "$(iso $((NOW0 - 50)))" '{machine_id:"mkbusy0001", state:"started", started_at:$a, app:"lane-run-mk"}')" >/dev/null
printf '[{"id":"mkbusy0001","state":"started","created_at":"%s","updated_at":"%s","config":{"guest":{"cpu_kind":"performance","cpus":4,"memory_mb":8192}}}]\n' \
  "$(iso $((NOW0 - 50)))" "$(iso $((NOW0 - 50)))" > "$FX/list-lane-run-mk.json"
q demo project-6-os 120; q demo project-3 120; tick
[ "$(nrun lane-run-mk)" = 0 ] && grep -q '\[lane-fleet:project-6\] tick .* max=1 action=none at-max' "$H/logs/lane-fleet.log" \
  && ok "N3 project-6 at max 1: none at-max" || bad "N3 mk: $(cat "$H/logs/lane-fleet.log")"
[ "$(nrun lane-run)" = 1 ] && ok "N3 the default fleet starts for project-3" || bad "N3 default: $(cat "$FX/fly.argv")"
grep -q 'adopted mkbusy0001' "$H/logs/lane-fleet.log" && bad "N3 the default pass must not see a group machine" || ok "N3 no fleet adopts or reconciles another app's machine"
[ "$(sql "SELECT state FROM lane_machines WHERE machine_id='mkbusy0001'" | jq -r '.rows[0].state')" = started ] \
  && ok "N3 the group machine's row is untouched by the default pass" || bad "N3 row: $(sql 'SELECT * FROM lane_machines')"

echo "N4: a missing group app is created, then waits for its secrets"
fresh $NOW0; setting lane_fleet.group.project-6 "$MK"
q demo project-6-os 120; q demo project-3 120; tick
grep -q '^apps create lane-run-mk --org fixture-org' "$FX/fly.argv" && ok "N4 apps create lane-run-mk in FLY_ORG" || bad "N4 argv: $(cat "$FX/fly.argv")"
[ "$(nrun lane-run-mk)" = 0 ] && ok "N4 no machine run in an app without its secrets" || bad "N4 argv: $(cat "$FX/fly.argv")"
[ "$(grep -c 'lane-run-mk has no HARNESS_SECRET' "$H/logs/ALERTS.log")" = 1 ] && grep -q 'flyctl secrets set .* -a lane-run-mk --stage' "$H/logs/ALERTS.log" \
  && ok "N4 one ALERTS line with the operator command" || bad "N4 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(nrun lane-run)" = 1 ] && ok "N4 the default pass still runs" || bad "N4 default: $(cat "$FX/fly.argv")"
tick
[ "$(grep -c 'apps create' "$FX/fly.argv")" = 1 ] && [ "$(grep -c 'lane-run-mk has no HARNESS_SECRET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok "N4 a second tick: no second create, no second alert" || bad "N4 2nd: $(cat "$FX/fly.argv") / $(cat "$H/logs/ALERTS.log")"
echo "$SECRETS" > "$FX/secrets-lane-run-mk.json"; tick
[ "$(nrun lane-run-mk)" = 1 ] && ok "N4 secrets set: the group starts its machine" || bad "N4 3rd: $(cat "$FX/fly.argv")"

echo "N5: no FLY_ORG -> no create, one ALERTS line"
fresh $NOW0; printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"; setting lane_fleet.group.project-6 "$MK"
q demo project-6-os 120; tick
[ "$(grep -c 'apps create' "$FX/fly.argv")" = 0 ] && [ "$(grep -c 'FLY_ORG' "$H/logs/ALERTS.log")" = 1 ] \
  && ok "N5 no create, one alert naming FLY_ORG" || bad "N5: $(cat "$FX/fly.argv") / $(cat "$H/logs/ALERTS.log")"

echo "N6: a deleted group row leaves its running machine started, with one orphan alert"
fresh $NOW0; groups_ready; setting lane_fleet.group.project-6 "$MK"
api POST /api/lane-fleet/machines "$(jq -nc --arg a "$(iso $((NOW0 - 50)))" '{machine_id:"mkorph0001", state:"started", started_at:$a, app:"lane-run-mk"}')" >/dev/null
printf '[{"id":"mkorph0001","state":"started","created_at":"%s","updated_at":"%s","config":{"guest":{"cpu_kind":"performance","cpus":4,"memory_mb":8192}}}]\n' \
  "$(iso $((NOW0 - 50)))" "$(iso $((NOW0 - 50)))" > "$FX/list-lane-run-mk.json"
sql "DELETE FROM settings WHERE key='lane_fleet.group.project-6'" >/dev/null
tick; tick
[ "$(sql "SELECT state FROM lane_machines WHERE machine_id='mkorph0001'" | jq -r '.rows[0].state')" = started ] \
  && ok "N6 the orphan's row stays started (not marked destroyed)" || bad "N6 row: $(sql 'SELECT * FROM lane_machines')"
grep -q 'mkorph0001' "$FX/fly.argv" && bad "N6 a flyctl call touched the orphan: $(cat "$FX/fly.argv")" || ok "N6 no flyctl call on the orphan"
[ "$(grep -c 'lane-run-mk/mkorph0001' "$H/logs/ALERTS.log")" = 1 ] && ok "N6 one orphan ALERTS line over 2 ticks" || bad "N6 alerts: $(cat "$H/logs/ALERTS.log")"
fresh $NOW0; setting lane_fleet.group.project-6 "$MK"; tick
grep -q 'orphan' "$H/logs/ALERTS.log" && bad "N6 an orphan alert with no orphan" || ok "N6 no orphan, no alert"

echo "N7: a group needs max_machines >= 1"
fresh $NOW0
setting lane_fleet.group.project-6 '{"app":"lane-run-mk","vm_size":"performance-4x","vm_memory":8192,"max_machines":4,"warm_floor":0,"projects":["project-6-os"]}'
setting lane_fleet.group.nomax '{"app":"lane-run-nm","projects":["project-5"]}'
G=$(api GET /api/lane-fleet/groups)
[ "$(jq -r '[.groups[].name] | join(" ")' <<<"$G")" = project-6 ] && [ "$(jq -r '.invalid[0].name' <<<"$G")" = nomax ] \
  && ok "N7 the proposed row is valid; a row with no max_machines is not" || bad "N7 groups: $G"

echo "F1: a grouped row past lane_run.group_fallback_s -> one alert, the default fleet takes it"
fresh $NOW0; groups_ready; setting lane_fleet.group.project-6 "$MK"; setting lane_run.group_fallback_s 600
echo '[]' > "$FX/secrets-lane-run-mk.json"; rm -f "$FX/list-lane-run-mk.json"   # the group fleet is gone
printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"                    # and cannot be re-created
q demo project-6-os 1000; tick
[ "$(grep -c 'project-6: a queued run waited 1000s' "$H/logs/ALERTS.log")" = 1 ] && ok "F1 one fallback ALERTS line" || bad "F1 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(nrun lane-run)" = 1 ] && grep -q '\[lane-fleet\] tick wait=1000 ' "$H/logs/lane-fleet.log" \
  && ok "F1 the default pass counts the stale grouped row and starts" || bad "F1: $(cat "$H/logs/lane-fleet.log")"
tick
[ "$(grep -c 'project-6: a queued run waited' "$H/logs/ALERTS.log")" = 1 ] && ok "F1 a second tick, same day: no second alert" || bad "F1 2nd: $(cat "$H/logs/ALERTS.log")"

echo "F2: group_fallback_s 0 -> never falls back"
fresh $NOW0; groups_ready; setting lane_fleet.group.project-6 "$MK"; setting lane_run.group_fallback_s 0
rm -f "$FX/list-lane-run-mk.json"; printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"
q demo project-6-os 5000; tick
[ "$(grep -c 'a queued run waited' "$H/logs/ALERTS.log")" = 0 ] && ok "F2 no fallback alert" || bad "F2 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(nrun lane-run)" = 0 ] && grep -q '\[lane-fleet\] tick wait=none ' "$H/logs/lane-fleet.log" \
  && ok "F2 the default pass does not count the grouped row" || bad "F2: $(cat "$H/logs/lane-fleet.log")"

# ============================================================================
for p in project-6-os project-5 project-3; do printf '%s o/%s - - 2 box-%s 192.0.2.1\n' "$p" "$p" "$p"; done > "$H/fleet.conf"
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
echo "\${@: -1}" >> "$T/runs.txt"
exit 0
EOF
chmod +x "$H/bin/fake-lane.sh"
work() { : > "$T/runs.txt"; env REPOS_ROOT="$T/norepos" "$@" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/wk.out" 2>&1; WRC=$?; }
qleft() { sql "SELECT project FROM lane_runs WHERE status='queued' ORDER BY project" | jq -r '[.rows[].project] | join(" ")'; }

echo "W1: LANE_RUN_GROUP=project-6 runs project-6-os rows only"
fresh $NOW0; setting lane_fleet.group.project-6 "$MK"; setting lane_fleet.group.project-5 "$TS"
q demo project-6-os 30; q demo2 project-6-os 20; q demo project-5 40; q demo project-3 50; work LANE_RUN_GROUP=project-6
[ "$WRC" = 0 ] && ok "W1 rc 0" || bad "W1 rc $WRC: $(cat "$T/wk.out")"
[ "$(sort "$T/runs.txt" | tr '\n' ' ')" = "project-6-os project-6-os " ] && ok "W1 ran the 2 project-6-os rows" || bad "W1 runs: $(cat "$T/runs.txt")"
[ "$(qleft)" = "project-3 project-5" ] && ok "W1 project-5 and project-3 stay queued" || bad "W1 left: $(qleft)"

echo "W2: LANE_RUN_GROUP with no valid row -> no claim"
fresh $NOW0; q demo project-3 50; work LANE_RUN_GROUP=nosuch
[ "$WRC" = 0 ] && [ ! -s "$T/runs.txt" ] && ok "W2 rc 0, nothing ran" || bad "W2 rc $WRC runs: $(cat "$T/runs.txt")"
grep -q 'POST /api/lane-runs/claim' "$WLOGF" && bad "W2 a claim was sent: $(cat "$WLOGF")" || ok "W2 no claim sent"
grep -q 'LANE_RUN_GROUP=nosuch has no valid lane_fleet.group.nosuch row' "$H/logs/lane-run-worker.log" && ok "W2 one log line" || bad "W2 log: $(cat "$H/logs/lane-run-worker.log")"
setting lane_run.poll_s 1; : > "$H/logs/lane-run-worker.log"
env REPOS_ROOT="$T/norepos" LANE_RUN_GROUP=nosuch timeout 60 "$H/bin/lane-run-worker.sh" --machine m1 > "$T/wk.out" 2>&1; WRC=$?
[ "$WRC" = 0 ] && grep -q 'no valid group row for 3 polls; exiting' "$H/logs/lane-run-worker.log" \
  && ok "W2 a long-running group worker with no row exits 0 after 3 polls" || bad "W2 exit rc $WRC: $(cat "$H/logs/lane-run-worker.log")"
[ "$(grep -c 'has no valid lane_fleet.group' "$H/logs/lane-run-worker.log")" = 1 ] && ok "W2 still one no-row line" || bad "W2 lines: $(cat "$H/logs/lane-run-worker.log")"
# R1 of #7447: a settings outage (500) is not a deleted row. 5 failed reads of
# the group row, then no row: the worker keeps running through the outage and
# exits only after 3 no-row polls.
: > "$H/logs/lane-run-worker.log"
curl -sS -X PUT "$JOBS_URL/__fail" -d '{"path":"/api/settings/lane_fleet.group.nosuch","n":5}' >/dev/null
env REPOS_ROOT="$T/norepos" LANE_RUN_GROUP=nosuch timeout 90 "$H/bin/lane-run-worker.sh" --machine m1 > "$T/wk.out" 2>&1; WRC=$?
nget=$(grep -c '^GET /api/settings/lane_fleet.group.nosuch ' "$WLOGF")
n500=$(grep -c '^GET /api/settings/lane_fleet.group.nosuch 500$' "$WLOGF")
[ "$WRC" = 0 ] && [ "$n500" = 5 ] && [ "$nget" -ge 8 ] && grep -q 'settings unreadable; no claim' "$H/logs/lane-run-worker.log" \
  && grep -q 'no valid group row for 3 polls; exiting' "$H/logs/lane-run-worker.log" \
  && ok "W2 an outage of 5 polls does not count; then 3 no-row polls exit ($nget reads, $n500 failed)" \
  || bad "W2 outage: rc $WRC reads $nget failed $n500 log: $(cat "$H/logs/lane-run-worker.log")"

echo "W3: no LANE_RUN_GROUP -> the default machine never runs a grouped row"
fresh $NOW0; setting lane_fleet.group.project-6 "$MK"
q demo project-6-os 30; q demo project-3 50; work
[ "$(tr '\n' ' ' < "$T/runs.txt")" = "project-3 " ] && [ "$(qleft)" = project-6-os ] && ok "W3 ran project-3 only" || bad "W3 runs: $(cat "$T/runs.txt") left: $(qleft)"

echo "R1: fly-idle-reaper signal_for covers the group apps"
REG="$REPO/catalog/fly-idle-signals.json"; REG_OK=1
eval "$(sed -n '/^signal_for() {/,/^}/p' "$REPO/bin/fly-idle-reaper.sh")"
eval "$(sed -n '/^has_entry() {/,/^}/p' "$REPO/bin/fly-idle-reaper.sh")"
[ "$(signal_for lane-run-mk)" = lane-run ] && [ "$(signal_for lane-run-ts)" = lane-run ] && ok "R1 lane-run-mk and lane-run-ts are source lane-run" || bad "R1 got $(signal_for lane-run-mk)"
[ "$(signal_for lane-run)" = lane-run ] && ok "R1 lane-run is still lane-run" || bad "R1 lane-run: $(signal_for lane-run)"
has_entry lane-run-mk && ok "R1 has_entry lane-run-mk (act stop is not refused as unregistered)" || bad "R1 has_entry"

echo
echo "lane-fleet-groups.bh-7434: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
