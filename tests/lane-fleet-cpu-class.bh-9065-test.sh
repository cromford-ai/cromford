#!/bin/bash
# tests/lane-fleet-cpu-class.bh-9065-test.sh — BH-9065 C4: a lane that needs
# CPU declares it in catalog/lanes.d/<lane>.json as
#   "machine": {"cpu": "performance", "size": "performance-4x"}
# and bin/lane-fleet.sh starts a machine of that size for that lane only. Every
# other run uses the fleet's size (lane_fleet.vm_size, or a group's vm_size).
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs, worker clock pinned), with a stub
# flyctl on LANE_FLEET_FLY that is app-aware and logs its argv. No real Fly
# call, no other vendor.
#
#   P1  a declared lane queued: one `machine run --vm-size performance-4x`
#       with --rm, --metadata lane_machine=<lane> and -e LANE_RUN_LANES=<lane>;
#       no group-size run for it
#   P2  an undeclared lane queued: one run of the group size shared-cpu-2x,
#       today's argv shape, no lane metadata
#   P3  both queued: one machine of each size in the same tick
#   P4  a stopped group-size machine is NOT reused for the declared lane
#   P5  a stopped lane machine is NOT reused for an undeclared lane
#   P6  a lane machine already started for the lane: no second one
#   P7  an idle lane machine whose lane has no queued run is stopped, at floor
#   P8  a fleet group (lane-run-mk, vm_size shared-cpu-2x): the declared lane
#       gets performance-4x on lane-run-mk with LANE_RUN_GROUP; the other lane
#       gets shared-cpu-2x
#   P9  an invalid machine key in a lane file: the group size, one log line
#   P10 max_machines counts a lane machine: at the ceiling, no fleet start
#   S1  bin/lanes-build.sh refuses {"cpu":"performance","size":"shared-cpu-2x"}
#   S2  bin/lanes-build.sh refuses a bad cpu value
#   S3  bin/lanes-build.sh accepts the valid form and an absent key
#
# Run from anywhere: tests/lane-fleet-cpu-class.bh-9065-test.sh (exit 0 = pass)
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
# The worker imports the git-ignored renders (as tests/lane-fleet-groups.bh-7434-test.sh).
"$REPO/bin/lanes-build.sh" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

# Unique lane ids per run: parallel runs on one commit never share a name.
U="$$"
LD="cpuheavy-$U"; LU="cpulight-$U"; LX="cpubad-$U"

H="$T/h"; FX="$T/fx"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog/lanes.d" "$FX"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$H"/bin/*.sh "$H"/bin/lib/*.sh 2>/dev/null
# The lane files: one declares a performance machine, one declares nothing,
# one declares a size outside its class.
jq -n --arg i "$LD" '{id:$i, machine:{cpu:"performance", size:"performance-4x"}}' > "$H/catalog/lanes.d/$LD.json"
jq -n --arg i "$LU" '{id:$i}' > "$H/catalog/lanes.d/$LU.json"
jq -n --arg i "$LX" '{id:$i, machine:{cpu:"performance", size:"shared-cpu-2x"}}' > "$H/catalog/lanes.d/$LX.json"

# The stub flyctl: fx/list-<app>.json is that app's listing, fx/secrets-<app>.json
# its secrets. Each `machine run` prints its own id.
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
app=""; prev=""
for a in "\$@"; do case "\$prev" in -a|--app) app="\$a" ;; esac; prev="\$a"; done
case "\$1 \$2" in
  "machine list") [ -f "$FX/list-\$app.json" ] || { echo "Error: Could not find App \"\$app\"" >&2; exit 1; }
                  cat "$FX/list-\$app.json" ;;
  "secrets list") cat "$FX/secrets-\$app.json" 2>/dev/null || echo '[]' ;;
  "machine run") n=\$(( \$(cat "$FX/run.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$FX/run.n"
                 s=\${app#lane-run}; s=\${s#-}; printf 'Machine ID: %sfixrun0%s\nState: created\n' "\${s:-dflt}" "\$n" ;;
  "machine start"|"machine stop") echo "fixture ok" ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl"
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0

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
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list-lane-run.json"
  printf 'FLY_API_TOKEN=fixture-fly-token\nFLY_ORG=fixture-org\n' > "$H/env/fly.env"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
  [ ! -e "$H/state/lane-fleet" ] || scratch_rm "$H/state/lane-fleet" || exit 1
  setting lane_fleet.warm_floor 0
}
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
# q <lane> <project> <seconds ago> — one queued row.
q() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES (?,?,'[\"bin/fake-lane.sh\"]',?,'queued')" \
  "$1" "$2" "$(iso $((NOW - $3)))" >/dev/null; }
# listing <app> <id>:<state>:<updated epoch>:<size>[:<lane>] ... — the app's listing.
listing() { local app=$1 a out="[]" id st up sz ln k c; shift
  for a in "$@"; do IFS=: read -r id st up sz ln <<<"$a"
    k=shared; [[ "$sz" == performance-* ]] && k=performance; c=${sz##*-}; c=${c%x}
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso "$up")" --arg k "$k" --argjson c "$c" --arg l "${ln:-}" \
      '. + [{id:$i, state:$s, created_at:$u, updated_at:$u,
             config:({image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:$k, cpus:$c, memory_mb:2048}}
                     + (if $l == "" then {} else {metadata:{lane_machine:$l}} end))}]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list-$app.json"; }
# row <mid> <state> <started epoch> [app] — a lane_machines row through the real route.
row() { api POST /api/lane-fleet/machines "$(jq -nc --arg m "$1" --arg s "$2" --arg a "$(iso "$3")" --arg app "${4:-lane-run}" \
  '{machine_id:$m, state:$s, started_at:$a, app:$app, cpu_kind:"shared", cpus:2, memory_mb:2048}')" >/dev/null; }
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; }
runs() { grep -E -- "^machine run " "$FX/fly.argv"; }
nruns() { runs | grep -c -- "${1:-.}"; }

fresh $NOW0; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T"/w*.err)"; exit 1; }

# ============================================================================
echo "P1: a declared lane gets a performance-4x machine for its run"
q "$LD" p1 120; tick
[ "$TRC" = 0 ] && ok "P1 tick rc 0" || bad "P1 rc $TRC"
[ "$(nruns)" = 1 ] && ok "P1 exactly one machine run" || bad "P1 runs: $(cat "$FX/fly.argv")"
R=$(runs)
grep -q -- "--vm-size performance-4x " <<<"$R" && ok "P1 argv has --vm-size performance-4x" || bad "P1 argv: $(runs)"
grep -q -- "--metadata lane_machine=$LD " <<<"$R" && grep -q -- "-e LANE_RUN_LANES=$LD" <<<"$R" \
  && ok "P1 the machine is tagged and env-scoped to its lane" || bad "P1 argv: $(runs)"
grep -q -- " --rm " <<<"$R" && ok "P1 --rm: a stopped lane machine is destroyed, never kept" || bad "P1 argv: $(runs)"
grep -q -- "--vm-memory 8192 " <<<"$R" && ok "P1 memory fits performance-4x (8192)" || bad "P1 argv: $(runs)"
[ "$(nruns shared-cpu-2x)" = 0 ] && ok "P1 no group-size machine for the declared lane" || bad "P1 argv: $(runs)"
[ "$(sql "SELECT cpu_kind, cpus FROM lane_machines" | jq -r '.rows[0] | "\(.cpu_kind) \(.cpus)"')" = "performance 4" ] \
  && ok "P1 its row records performance 4" || bad "P1 rows: $(sql 'SELECT * FROM lane_machines')"
grep -q "lane $LD: start dfltfixrun01 performance-4x" "$H/logs/lane-fleet.log" && ok "P1 one log line names the lane and size" \
  || bad "P1 log: $(cat "$H/logs/lane-fleet.log")"

echo "P2: an undeclared lane gets the group size shared-cpu-2x"
fresh $NOW0; q "$LU" p1 120; tick
R=$(runs)
[ "$(nruns)" = 1 ] && grep -q -- '--vm-size shared-cpu-2x --vm-memory 2048 -e LANE_RUN=1$' <<<"$R" \
  && ok "P2 one run, shared-cpu-2x, today's argv shape" || bad "P2 argv: $(cat "$FX/fly.argv")"
[ "$(nruns performance-4x)" = 0 ] && [ "$(nruns lane_machine)" = 0 ] && ok "P2 no lane machine" || bad "P2 argv: $(runs)"

echo "P3: both lanes queued -> one machine of each size"
fresh $NOW0; q "$LD" p1 120; q "$LU" p1 120; tick
[ "$(nruns)" = 2 ] && [ "$(nruns performance-4x)" = 1 ] && [ "$(nruns shared-cpu-2x)" = 1 ] \
  && ok "P3 one performance-4x and one shared-cpu-2x" || bad "P3 argv: $(cat "$FX/fly.argv")"

echo "P4: a stopped group-size machine is not reused for the declared lane"
fresh $NOW0; listing lane-run "grpstop01:stopped:$((NOW0 - 5000)):shared-cpu-2x"
q "$LD" p1 120; tick
[ "$(grep -c '^machine start' "$FX/fly.argv")" = 0 ] && [ "$(nruns performance-4x)" = 1 ] \
  && ok "P4 no machine start of grpstop01; a performance-4x run" || bad "P4 argv: $(cat "$FX/fly.argv")"

echo "P5: a stopped lane machine is not reused for an undeclared lane"
fresh $NOW0; listing lane-run "lnstop01:stopped:$((NOW0 - 5000)):performance-4x:$LD"
q "$LU" p1 120; tick
[ "$(grep -c '^machine start' "$FX/fly.argv")" = 0 ] && [ "$(nruns shared-cpu-2x)" = 1 ] \
  && ok "P5 no machine start of lnstop01; a shared-cpu-2x run" || bad "P5 argv: $(cat "$FX/fly.argv")"

echo "P6: a lane machine already started for the lane -> no second one"
fresh $NOW0; listing lane-run "lnlive01:started:$((NOW0 - 50)):performance-4x:$LD"
row lnlive01 started $((NOW0 - 50))
q "$LD" p1 120; tick
[ "$(nruns)" = 0 ] && ok "P6 no machine run" || bad "P6 argv: $(cat "$FX/fly.argv")"

echo "P7: an idle lane machine with no queued run of its lane is stopped, at floor"
fresh $NOW0; listing lane-run "lnidle01:started:$((NOW0 - 5000)):performance-4x:$LD"
row lnidle01 started $((NOW0 - 5000))
setting lane_fleet.warm_floor 1; tick
grep -q '^machine stop lnidle01 -a lane-run' "$FX/fly.argv" && ok "P7 machine stop lnidle01" || bad "P7 argv: $(cat "$FX/fly.argv")"
[ "$(sql "SELECT state FROM lane_machines WHERE machine_id='lnidle01'" | jq -r '.rows[0].state')" = stopped ] \
  && ok "P7 its row is stopped" || bad "P7 rows: $(sql 'SELECT * FROM lane_machines')"
[ "$(nruns shared-cpu-2x)" = 1 ] && ok "P7 the floor starts a group machine (the lane machine is not a floor machine)" \
  || bad "P7 argv: $(cat "$FX/fly.argv")"

echo "P8: a fleet group with vm_size shared-cpu-2x"
fresh $NOW0
echo '[]' > "$FX/list-lane-run-mk.json"
echo '[{"Name":"HARNESS_SECRET"},{"Name":"JOBS_URL"}]' > "$FX/secrets-lane-run-mk.json"
setting lane_fleet.group.project-6 '{"app":"lane-run-mk","vm_size":"shared-cpu-2x","vm_memory":4096,"max_machines":4,"projects":["project-6-os"]}'
q "$LD" project-6-os 120; q "$LU" project-6-os 120; tick
MK=$(grep -E -- '^machine run .* --app lane-run-mk ' "$FX/fly.argv")
[ "$(grep -c . <<<"$MK")" = 2 ] && ok "P8 two runs on lane-run-mk" || bad "P8 argv: $(cat "$FX/fly.argv")"
MKP=$(grep -- "--vm-size performance-4x " <<<"$MK")
grep -q -- "-e LANE_RUN_GROUP=project-6" <<<"$MKP" \
  && ok "P8 the declared lane: performance-4x with LANE_RUN_GROUP" || bad "P8 argv: $MK"
grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 -e LANE_RUN=1 -e LANE_RUN_GROUP=project-6$' <<<"$MK" \
  && ok "P8 the other lane: the group size shared-cpu-2x" || bad "P8 argv: $MK"

echo "P9: an invalid machine key -> the group size, one log line"
fresh $NOW0; q "$LX" p1 120; tick
[ "$(nruns)" = 1 ] && [ "$(nruns shared-cpu-2x)" = 1 ] && ok "P9 the group size" || bad "P9 argv: $(cat "$FX/fly.argv")"
grep -q "lane $LX: machine key in catalog/lanes.d/$LX.json is not valid" "$H/logs/lane-fleet.log" \
  && ok "P9 one log line names the file" || bad "P9 log: $(cat "$H/logs/lane-fleet.log")"

echo "P10: max_machines counts a lane machine"
fresh $NOW0; listing lane-run "lnmax01:started:$((NOW0 - 50)):performance-4x:$LD"
row lnmax01 started $((NOW0 - 50)); setting lane_fleet.max_machines 1
q "$LU" p1 120; tick
[ "$(nruns)" = 0 ] && grep -q 'max=1 action=none at-max' "$H/logs/lane-fleet.log" \
  && ok "P10 max 1 with one lane machine: the fleet starts nothing (at-max)" || bad "P10: $(cat "$FX/fly.argv") / $(cat "$H/logs/lane-fleet.log")"

# ============================================================================
# lanes-build over its own scratch root: one header, one lane file.
lb() { local d="$T/lb-$1"; mkdir -p "$d/catalog/lanes.d"
  cp "$REPO/catalog/lanes.d/_registry.json" "$d/catalog/lanes.d/"
  printf '%s\n' "$2" > "$d/catalog/lanes.d/lb$1-$U.json"
  LBOUT=$("$REPO/bin/lanes-build.sh" --root "$d" 2>&1 >/dev/null); LBRC=$?; }
echo "S1-S3: bin/lanes-build.sh validates the machine key"
lb s1 "{\"id\":\"lbs1-$U\",\"machine\":{\"cpu\":\"performance\",\"size\":\"shared-cpu-2x\"}}"
[ "$LBRC" = 1 ] && grep -q "machine" <<<"$LBOUT" && ok "S1 performance with shared-cpu-2x refused: $LBOUT" || bad "S1 rc $LBRC: $LBOUT"
lb s2 "{\"id\":\"lbs2-$U\",\"machine\":{\"cpu\":\"turbo\",\"size\":\"performance-4x\"}}"
[ "$LBRC" = 1 ] && grep -q "cpu" <<<"$LBOUT" && ok "S2 a bad cpu refused: $LBOUT" || bad "S2 rc $LBRC: $LBOUT"
lb s2b "{\"id\":\"lbs2b-$U\",\"machine\":{\"cpu\":\"performance\",\"size\":\"performance-3x\"}}"
[ "$LBRC" = 1 ] && ok "S2b performance-3x refused" || bad "S2b rc $LBRC: $LBOUT"
lb s2c "{\"id\":\"lbs2c-$U\",\"machine\":\"performance-4x\"}"
[ "$LBRC" = 1 ] && ok "S2c a machine key that is not an object refused" || bad "S2c rc $LBRC: $LBOUT"
lb s3 "{\"id\":\"lbs3-$U\",\"machine\":{\"cpu\":\"performance\",\"size\":\"performance-4x\"}}"
[ "$LBRC" = 0 ] && ok "S3 the valid performance form accepted" || bad "S3 rc $LBRC: $LBOUT"
lb s3b "{\"id\":\"lbs3b-$U\",\"machine\":{\"cpu\":\"shared\",\"size\":\"shared-cpu-8x\"}}"
[ "$LBRC" = 0 ] && ok "S3b the valid shared form accepted" || bad "S3b rc $LBRC: $LBOUT"
lb s3c "{\"id\":\"lbs3c-$U\"}"
[ "$LBRC" = 0 ] && ok "S3c an absent key accepted" || bad "S3c rc $LBRC: $LBOUT"

echo
echo "lane-fleet-cpu-class.bh-9065: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
