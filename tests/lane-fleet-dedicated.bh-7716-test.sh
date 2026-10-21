#!/bin/bash
# tests/lane-fleet-dedicated.bh-7716-test.sh — BH-7716 T4: the box group pass
# of bin/lane-fleet.sh. A lane_fleet.group.<name> row with `box` set (the seed
# row lane_fleet.group.dedicated, box fly-dedicated) is one dedicated machine
# for the lanes placed on that box: its machines get LANE_RUN_BOX,
# LANE_RUN_WORKERS and LANE_RUN_WARM_CLONES (no LANE_RUN_GROUP), a Fly volume
# on /root/repos, and the warm floor holds only while a placement row points
# at the box (A4).
#
# Driven through the REAL `bin/lane-fleet.sh tick` over real curl against the
# REAL jobs worker (worker/jobs/src/index.js on node:sqlite, as in
# tests/lane-fleet-worker.bh-6126.mjs). The group is the operator row
# lane_fleet.group.dedicated = tests/fixtures/bh-7716/dedicated-group.json, so
# the real worker's GET /api/lane-fleet/groups answers its box fields. One
# answer is a fixture (PUT /__over): GET /api/lane-runs/stats?run_p50=1&fleet=
# dedicated (`box`, `placed`). The stub flyctl on LANE_FLEET_FLY is app-aware
# and logs its argv. 0 network calls.
#
#   D1  placed, no machine: one volume create, one machine run with the box env,
#       the volume mount and the size; a second tick with the volume: 0 creates
#   D2  not placed + an idle started machine past idle_stop_s: one machine stop
#   D3  placed + the same idle machine: no stop (floor 1)
#   D4  the app has no secrets: 0 starts, 1 ALERTS line
#   D5  volume create fails: 0 machine run, 1 ALERTS line, none more that day
#   D6  a group without box still gets LANE_RUN_GROUP and no -v (regression)
#   D7  not placed, no machine row, no Fly app: 0 flyctl calls on the app,
#       0 ALERTS lines (the first tick after the merge)
#
# Run from anywhere: tests/lane-fleet-dedicated.bh-7716-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$REPO" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
"$REPO/bin/lanes-build.sh" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }

H="$T/h"; FX="$T/fx"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$FX"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$H"/bin/*.sh "$H"/bin/lib/*.sh 2>/dev/null

# The jobs worker: the real one, plus PUT /__over {path, body} that answers
# <body> for an exact request path (query included) instead of the worker.
cat > "$T/srv.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
const [, , ROOT, log, epoch0] = process.argv;
const clockMs = Number(epoch0) * 1000;
const RealDate = Date;
class FixtureDate extends RealDate {
  constructor(...a) { if (a.length === 0) super(clockMs); else super(...a); }
  static now() { return clockMs; }
}
globalThis.Date = FixtureDate;
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}/worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}/worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}/worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };
const over = new Map();
const handle = async (method, path, headers, body) => {
  if (path === '/__over') { const b = JSON.parse(body); over.set(b.path, b.body); return [200, '{"ok":true}']; }
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__sql') {
    const b = JSON.parse(body);
    const st = db.prepare(b.sql);
    const rows = /^\s*select/i.test(b.sql) ? st.all(...(b.params || [])) : (st.run(...(b.params || [])), []);
    return [200, JSON.stringify({ rows })];
  }
  if (method === 'GET' && over.has(path)) return [200, over.get(path)];
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
    method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  return [res.status, await res.text()];
};
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const body = Buffer.concat(chunks).toString('utf8');
    let code = 599; let out = '';
    try { [code, out] = await handle(req.method, req.url, req.headers, body); } catch (e) { out = String(e && e.message); }
    appendFileSync(log, `${req.method} ${req.url} ${code}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
EOF

# The stub flyctl. fx/list-<app>.json is the app's listing (no file = no app),
# fx/secrets-<app>.json its secrets, fx/vols-<app>.json its volumes. A
# `volumes create` adds the volume; fx/volcreate.fail makes it fail.
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
  "volumes list") [ -f "$FX/vollist.fail" ] && { echo "Error: fixture volumes list failure" >&2; exit 1; }
                  cat "$FX/vols-\$app.json" 2>/dev/null || echo '[]' ;;
  "volumes create") [ -f "$FX/volcreate.fail" ] && { echo "Error: fixture volume create failure" >&2; exit 1; }
                  v=\$(cat "$FX/vols-\$app.json" 2>/dev/null || echo '[]')
                  jq -c --arg n "\$3" '. + [{id:"vol_fixture", name:\$n, state:"created"}]' <<<"\$v" > "$FX/vols-\$app.json"
                  echo "ID: vol_fixture" ;;
  "machine run") n=\$(( \$(cat "$FX/run.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$FX/run.n"
                 s=\${app#lane-run}; s=\${s#-}; printf 'Machine ID: %sfixrun0%s\nState: created\n' "\${s:-dflt}" "\$n" ;;
  "machine start"|"machine stop") echo "fixture ok" ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl"
unset FLY_REGION
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0
APP=lane-run-dedicated
# The go-live operator row (T1 contract), from the shared fixture.
DED=$(jq -c . "$REPO/tests/fixtures/bh-7716/dedicated-group.json") || { echo "FAIL: no tests/fixtures/bh-7716/dedicated-group.json"; exit 1; }
MKROW='{"app":"lane-run-mk","vm_size":"performance-4x","vm_memory":8192,"max_machines":4,"projects":["project-6-os"]}'
SECRETS='[{"Name":"HARNESS_SECRET"},{"Name":"JOBS_URL"}]'

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  NOW=$1; export LANE_FLEET_NOW=$1
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$T/srv.mjs" "$REPO" "$T/w$n.log" "$1" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w$n.err")"; exit 1; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  WLOGF="$T/w$n.log"
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list-lane-run.json"
  echo '[]' > "$FX/list-$APP.json"; echo "$SECRETS" > "$FX/secrets-$APP.json"
  printf 'FLY_API_TOKEN=fixture-fly-token\nFLY_ORG=fixture-org\n' > "$H/env/fly.env"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
  [ ! -e "$H/state/lane-fleet" ] || scratch_rm "$H/state/lane-fleet" || exit 1
  setting lane_fleet.warm_floor 0
  setting lane_fleet.group.dedicated "$DED"; placed true
}
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
over() { curl -sS -X PUT "$JOBS_URL/__over" -d "$(jq -nc --arg p "$1" --arg b "$2" '{path:$p, body:$b}')" >/dev/null; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
# placed <true|false> — the dedicated fleet's stats answer (no queued lane).
placed() { over "/api/lane-runs/stats?run_p50=1&fleet=dedicated" "{\"lanes\":[],\"box\":\"fly-dedicated\",\"placed\":$1}"; }
# idle_machine — one started machine of the app, started 1000 s ago (idle_s 1000 > 600).
idle_machine() {
  api POST /api/lane-fleet/machines "$(jq -nc --arg a "$(iso $((NOW - 1000)))" --arg app "$APP" \
    '{machine_id:"dedidle0001", state:"started", started_at:$a, app:$app, cpu_kind:"performance", cpus:8, memory_mb:16384}')" >/dev/null
  printf '[{"id":"dedidle0001","state":"started","created_at":"%s","updated_at":"%s","config":{"guest":{"cpu_kind":"performance","cpus":8,"memory_mb":16384}}}]\n' \
    "$(iso $((NOW - 1000)))" "$(iso $((NOW - 1000)))" > "$FX/list-$APP.json"
}
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; }
runs_for() { grep -E -- "^machine run .* --app $1 " "$FX/fly.argv"; }
nrun() { runs_for "$1" | grep -c .; }
napp() { grep -cE -- "(-a|--app) $APP( |$)" "$FX/fly.argv"; }
nalert() { grep -c . "$H/logs/ALERTS.log"; }
dlog() { grep '\[lane-fleet:dedicated\]' "$H/logs/lane-fleet.log"; }

# ============================================================================
echo "D1: placed, no machine -> one volume create, one machine run with the box env"
fresh $NOW0
G=$(api GET /api/lane-fleet/groups)
[ "$(jq -r '.groups[] | select(.name == "dedicated") | "\(.box) \(.volume) \(.workers) \(.projects | length)"' <<<"$G")" = "fly-dedicated repos 6 0" ] \
  && ok "D1 the real groups answer carries the box fields" || bad "D1 groups: $G"
tick
[ "$TRC" = 0 ] && ok "D1 tick rc 0" || bad "D1 rc $TRC"
R=$(runs_for $APP)
if [ "$(nrun $APP)" = 1 ]; then ok "D1 exactly one machine run on $APP"; else bad "D1 runs: $(cat "$FX/fly.argv")"; fi
for a in '--vm-size performance-8x' '--vm-memory 16384' '-v repos:/root/repos' '--region iad' '-e LANE_RUN=1' \
         '-e LANE_RUN_BOX=fly-dedicated' '-e LANE_RUN_WORKERS=6' '-e LANE_RUN_WARM_CLONES=1'; do
  [[ " $R " == *" $a "* ]] && ok "D1 run argv has '$a'" || bad "D1 run argv lacks '$a': $R"
done
[[ "$R" == *LANE_RUN_GROUP* ]] && bad "D1 a box machine got LANE_RUN_GROUP: $R" || ok "D1 no LANE_RUN_GROUP on a box machine"
grep -q "^volumes list --app $APP --json$" "$FX/fly.argv" && ok "D1 volumes list --app $APP --json" || bad "D1 argv: $(cat "$FX/fly.argv")"
[ "$(grep -c '^volumes create' "$FX/fly.argv")" = 1 ] && grep -q "^volumes create repos --app $APP --size 20 --region iad --yes$" "$FX/fly.argv" \
  && ok "D1 one volumes create repos --app $APP --size 20 --region iad --yes" || bad "D1 argv: $(cat "$FX/fly.argv")"
[ "$(grep -n '^volumes create' "$FX/fly.argv" | cut -d: -f1)" -lt "$(grep -n '^machine run' "$FX/fly.argv" | grep -- "--app $APP" | cut -d: -f1)" ] 2>/dev/null \
  && ok "D1 the volume is created before the machine run" || bad "D1 order: $(cat "$FX/fly.argv")"
dlog | grep -q 'tick wait=none live=0 inflight=0 floor=1 max=1 action=start dedicatedfixrun01 below-floor' \
  && ok "D1 tick line: floor=1 action=start <mid> below-floor" || bad "D1 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(sql "SELECT COUNT(*) AS n FROM lane_machines WHERE app=? AND state='starting'" "$APP" | jq '.rows[0].n')" = 1 ] \
  && ok "D1 one starting row with app $APP" || bad "D1 rows: $(sql 'SELECT machine_id, app, state FROM lane_machines')"
[ "$(nalert)" = 0 ] && ok "D1 no ALERTS line" || bad "D1 alerts: $(cat "$H/logs/ALERTS.log")"
# The second tick: the volume now exists; the started row is gone, so the pass
# starts again and must not create a second volume.
sql "DELETE FROM lane_machines" >/dev/null; : > "$FX/fly.argv"; tick
[ "$(nrun $APP)" = 1 ] && ok "D1 second tick: one more machine run" || bad "D1 2nd runs: $(cat "$FX/fly.argv")"
[ "$(grep -c '^volumes create' "$FX/fly.argv")" = 0 ] && grep -q "^volumes list --app $APP --json$" "$FX/fly.argv" \
  && ok "D1 second tick: the volume exists, 0 creates" || bad "D1 2nd argv: $(cat "$FX/fly.argv")"

echo "D2: not placed + an idle started machine past idle_stop_s -> one machine stop"
fresh $NOW0; placed false; idle_machine; tick
[ "$(grep -c "^machine stop dedidle0001 -a $APP" "$FX/fly.argv")" = 1 ] && ok "D2 one machine stop dedidle0001" || bad "D2 argv: $(cat "$FX/fly.argv")"
[ "$(nrun $APP)" = 0 ] && ok "D2 no start" || bad "D2 runs: $(cat "$FX/fly.argv")"
dlog | grep -q 'box fly-dedicated: no placement row; floor 0' && ok "D2 log: no placement row; floor 0" || bad "D2 log: $(cat "$H/logs/lane-fleet.log")"
dlog | grep -q 'tick wait=none live=1 inflight=0 floor=0 max=1 action=stop dedidle0001 idle=1000' \
  && ok "D2 tick line: floor=0 action=stop" || bad "D2 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(sql "SELECT state FROM lane_machines WHERE machine_id='dedidle0001'" | jq -r '.rows[0].state')" = stopped ] \
  && ok "D2 the row is stopped" || bad "D2 rows: $(sql 'SELECT * FROM lane_machines')"

echo "D3: placed + the same idle machine -> no stop (floor 1)"
fresh $NOW0; idle_machine; tick
[ "$(grep -c '^machine stop' "$FX/fly.argv")" = 0 ] && ok "D3 no machine stop" || bad "D3 argv: $(cat "$FX/fly.argv")"
[ "$(nrun $APP)" = 0 ] && ok "D3 no start (live 1 = floor 1)" || bad "D3 runs: $(cat "$FX/fly.argv")"
dlog | grep -q 'tick wait=none live=1 inflight=0 floor=1 max=1 action=none' && ok "D3 tick line: floor=1 action=none" || bad "D3 log: $(cat "$H/logs/lane-fleet.log")"
grep -q 'no placement row' <<<"$(dlog)" && bad "D3 a no-placement line while placed" || ok "D3 no no-placement line"

echo "D4: the app has no secrets -> 0 starts, 1 ALERTS line"
fresh $NOW0; echo '[]' > "$FX/secrets-$APP.json"; tick
[ "$(nrun $APP)" = 0 ] && [ "$(grep -c '^volumes' "$FX/fly.argv")" = 0 ] && ok "D4 no machine run, no volume call" || bad "D4 argv: $(cat "$FX/fly.argv")"
[ "$(nalert)" = 1 ] && grep -q "$APP has no HARNESS_SECRET or JOBS_URL secret" "$H/logs/ALERTS.log" \
  && ok "D4 one ALERTS line naming the secrets" || bad "D4 alerts: $(cat "$H/logs/ALERTS.log")"

echo "D5: volume create fails -> 0 machine run, 1 ALERTS line, none more that day"
fresh $NOW0; touch "$FX/volcreate.fail"; tick
[ "$(nrun $APP)" = 0 ] && ok "D5 no machine run" || bad "D5 argv: $(cat "$FX/fly.argv")"
[ "$(grep -c '^volumes create' "$FX/fly.argv")" = 1 ] && ok "D5 one create try" || bad "D5 argv: $(cat "$FX/fly.argv")"
[ "$(nalert)" = 1 ] && grep -q 'volumes create repos' "$H/logs/ALERTS.log" && ok "D5 one ALERTS line naming the create" || bad "D5 alerts: $(cat "$H/logs/ALERTS.log")"
dlog | grep -q 'volume repos: volumes create failed' && ok "D5 a log line" || bad "D5 log: $(cat "$H/logs/lane-fleet.log")"
dlog | grep -q 'tick .* action=none volume-failed' && ok "D5 tick line: action=none volume-failed" || bad "D5 log: $(cat "$H/logs/lane-fleet.log")"
tick
[ "$(nrun $APP)" = 0 ] && [ "$(nalert)" = 1 ] && ok "D5 second tick, same UTC day: no run, no second ALERTS line" || bad "D5 2nd: $(cat "$FX/fly.argv") / $(cat "$H/logs/ALERTS.log")"
rm -f "$FX/volcreate.fail"; touch "$FX/vollist.fail"; : > "$FX/fly.argv"; tick
[ "$(nrun $APP)" = 0 ] && [ "$(grep -c '^volumes create' "$FX/fly.argv")" = 0 ] && ok "D5 a failed volumes list: no create, no run" || bad "D5 list: $(cat "$FX/fly.argv")"

echo "D6: a group without box keeps LANE_RUN_GROUP and no -v"
fresh $NOW0; setting lane_fleet.group.project-6 "$MKROW"
echo '[]' > "$FX/list-lane-run-mk.json"; echo "$SECRETS" > "$FX/secrets-lane-run-mk.json"
placed false
[ "$(api GET /api/lane-fleet/groups | jq -r '.groups[] | select(.name == "project-6") | has("box")')" = false ] \
  && ok "D6 a projects group object has no box key" || bad "D6 groups: $(api GET /api/lane-fleet/groups)"
sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES ('demo','project-6-os','[\"bin/x.sh\"]',?,'queued')" "$(iso $((NOW - 120)))" >/dev/null
tick
[ "$(nrun lane-run-mk)" = 1 ] && runs_for lane-run-mk | grep -q -- '--vm-size performance-4x --vm-memory 8192 -e LANE_RUN=1 -e LANE_RUN_GROUP=project-6$' \
  && ok "D6 project-6 run argv as before BH-7716 (LANE_RUN_GROUP, no -v)" || bad "D6 argv: $(cat "$FX/fly.argv")"
grep -qE -- ' -v |LANE_RUN_BOX|--region' <<<"$(runs_for lane-run-mk)" && bad "D6 box flags on a projects group" || ok "D6 no box flags on a projects group"
grep -q '^volumes' "$FX/fly.argv" && bad "D6 a volumes call: $(cat "$FX/fly.argv")" || ok "D6 no volumes call"

echo "D7: not placed, no machine row, no Fly app -> nothing on the app, no alert"
fresh $NOW0; placed false; rm -f "$FX/list-$APP.json" "$FX/secrets-$APP.json"; tick
[ "$TRC" = 0 ] && ok "D7 tick rc 0" || bad "D7 rc $TRC"
[ "$(napp)" = 0 ] && ok "D7 0 flyctl calls on $APP" || bad "D7 argv: $(cat "$FX/fly.argv")"
grep -q '^apps create' "$FX/fly.argv" && bad "D7 an apps create" || ok "D7 no apps create"
[ "$(nalert)" = 0 ] && ok "D7 0 ALERTS lines" || bad "D7 alerts: $(cat "$H/logs/ALERTS.log")"
dlog | grep -q 'box fly-dedicated: no placement row and no machine; nothing to do' && ok "D7 one log line" || bad "D7 log: $(cat "$H/logs/lane-fleet.log")"

echo
echo "lane-fleet-dedicated.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
