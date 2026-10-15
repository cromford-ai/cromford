#!/bin/bash
# tests/lane-fleet.bh-6126-test.sh — BH-6126 (BH-6047 part 3 of 5): the
# lane-run Fly fleet autoscaler, bin/lane-fleet.sh tick, and the machine boot
# fly/lane-run-entrypoint.sh.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs, worker clock pinned to the tick's
# LANE_FLEET_NOW), with a stub flyctl on LANE_FLEET_FLY that logs its argv and
# answers `machine list --json` from a fixture file.
#
#   D1-D17 lf_decide / lf_pick_stop table, with the adversarial negatives
#   A0  no machine, wait 300: one `machine run --app lane-run`, no other app
#   A0b lane_fleet.vm_size=shared-cpu-4x reaches --vm-size
#   A1  live 1 = floor, wait 300: +1 machine, row starting + in_flight
#   A2  next tick: no second start (none start-in-flight)
#   A3  2 live idle machines over idle_stop_s: exactly one stop, the more idle
#   A4  1 live machine idle 9999 at floor 1: no stop
#   A5  cost rows per minute keyed on lane and machine; replay writes 0
#   A6  49 started machines, max_machines=0: the 50th starts
#   A7  a stopped machine is reused (`machine start`), no `machine run`
#   C1  a Fly started machine with no row, younger than grace: in flight
#   C2  wait over threshold at max: no start and no stop
#   C3  max_machines "abc" and " 0 " fall back to 0, not to a ceiling
#   F1  lock held: no flyctl call
#   F2  JOBS_URL empty: no flyctl call, "not configured"
#   F3  stats answers 500: no start, one ALERTS line
#   F4  machine run prints no Machine ID: no row, one ALERTS line in 2 ticks
#   F5  reuse fails: machine destroy --force, "not found" = gone
#   F6  entrypoint: exec argv, mode 600, exit 78, no secret printed
#   G1  a reused machine with a claim from an earlier life is in flight again:
#       the next tick, wait still over, starts nothing
#   G2  a `starting` row past grace that Fly still runs, wait 300: stopped,
#       one ALERTS line, no machine run; the next tick holds (backoff)
#   G3  a start that exits at boot: no restart every minute, one ALERTS line,
#       its minute is billed; after the backoff the reuse runs again
#   G4  wait 30 (a queued run under the threshold), 2 idle machines: no stop
#   G5  reconcile bills a stopped machine up to Fly's stop time, not to now
#       (floor 0, so the floor does not reuse it in the same tick)
#   G6  lane_fleet.image outside registry.fly.io/lane-run is not used
#   H1  the warm floor holds (re-review finding 1): floor 1, empty queue, a
#       healthy machine, 25 ticks: 1 machine run, 0 machine stop, 0 ALERTS; the
#       row is promoted to started once past grace (Fly started, no run waited)
#   H2  a busy `starting` row is never a failed start (re-review finding 2):
#       its live claim is 3 s older than its started_at; no stop, no ALERTS
#   H3  a start is recorded at the tick's decision time, not the POST time, so
#       a claim made before the POST lands still counts
#
# Run from anywhere: tests/lane-fleet.bh-6126-test.sh (exit 0 = pass)
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
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$T/fx"
# BH-6741: the tick loads the Fly token from env/fly.env and makes no Fly call without one.
printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -x "$H/bin/lane-fleet.sh" ] && ok "closure installs bin/lane-fleet.sh" || bad "closure lacks bin/lane-fleet.sh"

# The stub flyctl: argv to fx/fly.argv, answers from fx/ files.
FX="$T/fx"
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
case "\$1 \$2" in
  "machine list") if [ -f "$FX/list.fail" ]; then echo "Error: fixture list failure" >&2; exit 1; fi; cat "$FX/list.json" ;;
  "machine run") cat "$FX/run.out" ;;
  "machine start") if [ -f "$FX/start.fail" ]; then echo "Error: fixture start failure" >&2; exit 1; fi; echo "fixture started" ;;
  "machine stop") echo "fixture stopped" ;;
  "machine destroy") cat "$FX/destroy.out" 2>/dev/null; exit "\$(cat "$FX/destroy.rc" 2>/dev/null || echo 0)" ;;
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
# fresh <epoch> — a new worker with an empty database, its clock at <epoch>;
# clears the stub's files, the logs and the alert flags.
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
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list.json"
  printf 'Machine ID: %s\nState: created\n' fixturenew01 > "$FX/run.out"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
}
clock() { NOW=$1; export LANE_FLEET_NOW=$1; curl -sS -X PUT "$JOBS_URL/__clock" -d "{\"epoch\":$1}" >/dev/null; }
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
# row <mid> <state> <started epoch> — a lane_machines row through the real route.
row() { api POST /api/lane-fleet/machines "$(jq -nc --arg m "$1" --arg s "$2" --arg a "$(iso "$3")" \
  '{machine_id:$m, state:$s, started_at:$a, cpu_kind:"shared", cpus:2, memory_mb:2048}')" >/dev/null; }
# listing <id>:<state>:<updated epoch> ... — the stub's `machine list --json`.
listing() { local a out="[]" id st up
  for a in "$@"; do IFS=: read -r id st up <<<"$a"
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso "$up")" \
      '. + [{id:$i, state:$s, created_at:$u, updated_at:$u, config:{image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:"shared", cpus:2, memory_mb:2048}}}]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list.json"; }
# queued <seconds ago> — one queued lane_runs row.
queued() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES ('demo','p1','[\"bin/x.sh\"]',?,'queued')" "$(iso $((NOW - $1)))" >/dev/null; }
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; LAST=$(tail -n 1 "$H/logs/lane-fleet.log"); }
nfly() { grep -c -- "$1" "$FX/fly.argv"; }
nalerts() { grep -c "$1" "$H/logs/ALERTS.log"; }
lm() { sql "SELECT machine_id, state FROM lane_machines ORDER BY machine_id" | jq -r '.rows[] | "\(.machine_id)=\(.state)"' | tr '\n' ' '; }

# ============================================================================
echo "D: lf_decide / lf_pick_stop table"
( . "$H/bin/lane-fleet.sh"
  chk() { local want="$1" got; shift; got=$(lf_decide "$@")
    [ "$got" = "$want" ] && echo "ok lf_decide $* -> $got" || echo "FAIL lf_decide $* -> '$got' (want '$want')"; }
  chk "start queue-wait" 300 1 0 1 60 0                # D1
  chk "start queue-wait" 61 3 0 1 60 0                 # D2
  chk "start below-floor" none 0 0 1 60 0              # D3
  chk "start queue-wait" 300 49 0 1 60 0               # D4: 0 = no ceiling
  chk "none start-in-flight" 86400 1 1 1 60 0          # D5
  chk "none wait-under-threshold" 60 1 0 1 60 0        # D6: equal is not over
  chk "none wait-under-threshold" none 1 0 1 60 0      # D7
  chk "none start-in-flight" 300 4 1 1 60 5            # D8: 4 live + 1 in flight at max 5
  chk "none at-max" 300 5 0 1 60 5                     # D9
  chk "start below-floor" none 0 0 1 60 0              # D9b
  chk "none failed-start-hold" 300 1 0 1 60 0 1        # D15: hold beats wait
  chk "none failed-start-hold" none 0 0 1 60 0 1       # D16: hold beats floor
  chk "none start-in-flight" 300 1 1 1 60 0 1          # D17
  pk() { local want="$1" got; shift; got=$(lf_pick_stop "$@")
    [ "$got" = "$want" ] && echo "ok lf_pick_stop $1 $2 $3 -> '${got}'" || echo "FAIL lf_pick_stop $1 $2 $3 -> '$got' (want '$want')"; }
  M='{"busy":false,"in_flight":false}'
  pk fixturea01 2 1 600 "[$(jq -c '. + {machine_id:"fixturea01", idle_s:601}' <<<"$M")]"                       # D10
  pk fixtureb02 3 1 600 "[$(jq -c '. + {machine_id:"fixturea01", idle_s:700}' <<<"$M"),$(jq -c '. + {machine_id:"fixtureb02", idle_s:900}' <<<"$M")]"  # D11
  pk "" 1 1 600 "[$(jq -c '. + {machine_id:"fixturea01", idle_s:9999}' <<<"$M")]"                              # D12: floor
  pk "" 2 1 600 "[$(jq -c '. + {machine_id:"fixturea01", idle_s:600}' <<<"$M")]"                               # D13: equal
  pk "" 2 1 600 '[{"machine_id":"fixturea01","idle_s":9999,"busy":true,"in_flight":false}]'                      # D14: busy
  pk "" 2 1 600 '[{"machine_id":"fixturea01","idle_s":9999,"busy":false,"in_flight":true}]'                      # D14b: in flight
) > "$T/d.out" 2>&1
while IFS= read -r l; do case "$l" in ok*) ok "D ${l#ok }" ;; *) bad "D $l" ;; esac; done < "$T/d.out"

fresh $NOW0; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T"/w*.err)"; exit 1; }

# ============================================================================
echo "A0: no machine, wait 300 -> one machine run in app lane-run"
queued 300; tick
[ "$TRC" = 0 ] && ok "A0 tick rc 0" || bad "A0 rc=$TRC"
[ "$(nfly 'machine run')" = 1 ] && ok "A0 one machine run" || bad "A0 run lines: $(cat "$FX/fly.argv")"
grep 'machine run' "$FX/fly.argv" | grep -q -- '--app lane-run ' && ok "A0 machine run has --app lane-run" || bad "A0 argv: $(cat "$FX/fly.argv")"
others=$(grep -oE -- '(-a|--app) [^ ]+' "$FX/fly.argv" | grep -vcE -- ' lane-run$')
[ "$others" = 0 ] && ok "A0 no flyctl call names another app" || bad "A0 other apps: $(cat "$FX/fly.argv")"
grep 'machine run' "$FX/fly.argv" | grep -q -- '--vm-size shared-cpu-2x --vm-memory 2048' && ok "A0 size from the seeded rows" || bad "A0 size: $(cat "$FX/fly.argv")"
case "$LAST" in *"action=start fixturenew01 below-floor"*) ok "A0 log: start below-floor" ;; *) bad "A0 log: $LAST" ;; esac

echo "A0b: lane_fleet.vm_size=shared-cpu-4x"
fresh $NOW0; setting lane_fleet.vm_size shared-cpu-4x; setting lane_fleet.vm_memory_mb 4096; tick
grep 'machine run' "$FX/fly.argv" | grep -q -- '--vm-size shared-cpu-4x --vm-memory 4096' && ok "A0b the size rows reach --vm-size/--vm-memory" || bad "A0b argv: $(cat "$FX/fly.argv")"
r=$(api GET /api/lane-fleet/machines | jq -c '.machines[0] | [.cpu_kind, .cpus, .memory_mb]')
[ "$r" = '["shared",4,4096]' ] && ok "A0b the row records the size" || bad "A0b row size: $r"

# ============================================================================
echo "A1: live 1 at floor 1, wait 300 -> +1 machine, recorded in flight"
fresh $NOW0
row fixturelive1 started $((NOW0 - 1000)); listing "fixturelive1:started:$((NOW0 - 1000))"; queued 300
grep -qi approv <<<"$(ls "$H/flags")" && bad "A1 an approval flag exists" || ok "A1 no approval flag present"
tick
[ "$(nfly 'machine run')" = 1 ] && ok "A1 one machine run" || bad "A1 argv: $(cat "$FX/fly.argv")"
[ "$(nfly 'machine stop')" = 0 ] && ok "A1 no stop while scaling up" || bad "A1 stopped: $(cat "$FX/fly.argv")"
g=$(api GET /api/lane-fleet/machines | jq -c '.machines[] | select(.machine_id=="fixturenew01") | [.state, .in_flight]')
[ "$g" = '["starting",true]' ] && ok "A1 GET shows fixturenew01 starting, in_flight" || bad "A1 GET: $g"
case "$LAST" in *"live=1 inflight=0 floor=1 max=none action=start fixturenew01 queue-wait"*) ok "A1 log: start queue-wait" ;; *) bad "A1 log: $LAST" ;; esac

echo "A2: the next tick (+30 s) -> no second start"
clock $((NOW0 + 30)); listing "fixturelive1:started:$((NOW0 - 1000))" "fixturenew01:started:$NOW0"
: > "$FX/fly.argv"; tick
[ "$(grep -cE 'machine (run|start)' "$FX/fly.argv")" = 0 ] && ok "A2 no machine run/start" || bad "A2 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"inflight=1"*"action=none start-in-flight"*) ok "A2 log: none start-in-flight" ;; *) bad "A2 log: $LAST" ;; esac

# ============================================================================
echo "A3: 2 live, idle 700/800 s, no queue -> exactly one stop, the more idle"
fresh $NOW0
row fixturem0001 started $((NOW0 - 700)); row fixturem0002 started $((NOW0 - 800))
listing "fixturem0001:started:$((NOW0 - 700))" "fixturem0002:started:$((NOW0 - 800))"
tick
[ "$(nfly 'machine stop')" = 1 ] && ok "A3 exactly one machine stop" || bad "A3 argv: $(cat "$FX/fly.argv")"
grep -q 'machine stop fixturem0002 -a lane-run' "$FX/fly.argv" && ok "A3 stops the more idle machine" || bad "A3 argv: $(cat "$FX/fly.argv")"
[ "$(lm)" = "fixturem0001=started fixturem0002=stopped " ] && ok "A3 its row is stopped" || bad "A3 rows: $(lm)"
case "$LAST" in *"action=stop fixturem0002 idle=800"*) ok "A3 log: stop idle=800" ;; *) bad "A3 log: $LAST" ;; esac
[ "$(nfly 'machine run')" = 0 ] && ok "A3 no start" || bad "A3 started"

echo "A4: 1 live idle 9999 s at floor 1 -> no stop"
fresh $NOW0; row fixturem0001 started $((NOW0 - 9999)); listing "fixturem0001:started:$((NOW0 - 9999))"
tick
[ "$(nfly 'machine stop')" = 0 ] && ok "A4 never stops the last machine at the floor" || bad "A4 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"live=1"*"action=none wait-under-threshold"*) ok "A4 log: none" ;; *) bad "A4 log: $LAST" ;; esac

# ============================================================================
echo "A5: cost rows per lane and machine"
T0=1791000000   # 2026-10-03T04:00:00Z, a whole minute
fresh $((T0 + 240))
row fixturecost1 started "$T0"; listing "fixturecost1:started:$T0"
sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, status, finished_at, rc)
     VALUES ('alpha','p1','[\"bin/x.sh\"]',?,?,'fixturecost1','done',?,0)" "$(iso "$T0")" "$(iso "$T0")" "$(iso $((T0 + 170)))" >/dev/null
tick
c=$(sql "SELECT lane_id, COUNT(*) AS n FROM cost_rows WHERE box='lane-run-fixturecost1' GROUP BY lane_id ORDER BY lane_id" | jq -c '[.rows[] | "\(.lane_id)=\(.n)"]')
[ "$c" = '["alpha=3","lane-fleet=1"]' ] && ok "A5 4 rows: 3 alpha, 1 lane-fleet" || bad "A5 rows: $c"
p=$(sql "SELECT DISTINCT project FROM cost_rows WHERE lane_id='alpha'" | jq -c '[.rows[].project]')
[ "$p" = '["p1"]' ] && ok "A5 the alpha rows carry project p1" || bad "A5 project: $p"
u=$(sql "SELECT COUNT(*) AS n FROM cost_rows WHERE box='lane-run-fixturecost1' AND cost_usd > 0 AND stage='infra' AND runner='fly'" | jq '.rows[0].n')
[ "$u" = 4 ] && ok "A5 each row is a priced fly infra row" || bad "A5 priced rows: $u"
case "$LAST" in *"cost=4/0"*) ok "A5 log: cost=4/0" ;; *) bad "A5 log: $LAST" ;; esac
tick
case "$LAST" in *"cost=0/"*) ok "A5 a second tick in the same minute writes 0" ;; *) bad "A5 replay log: $LAST" ;; esac
n=$(sql "SELECT COUNT(*) AS n FROM cost_rows" | jq '.rows[0].n')
[ "$n" = 4 ] && ok "A5 still 4 rows" || bad "A5 rows after replay: $n"

# ============================================================================
echo "A6: 49 started machines, max_machines=0, wait 300 -> the 50th starts"
fresh $NOW0; args=()
for i in $(seq -w 1 49); do args+=("fixturebulk$i:started:$((NOW0 - 1000))"); done
listing "${args[@]}"; queued 300; tick
[ "$(nfly 'machine run')" = 1 ] && ok "A6 one machine run" || bad "A6 argv: $(grep -c . "$FX/fly.argv") lines"
case "$LAST" in *"live=49 inflight=0 floor=1 max=none action=start fixturenew01 queue-wait"*) ok "A6 log: live=49, start" ;; *) bad "A6 log: $LAST" ;; esac
[ "$(sql "SELECT COUNT(*) AS n FROM lane_machines WHERE state='started'" | jq '.rows[0].n')" = 49 ] && ok "A6 the 49 hand-made machines are adopted" || bad "A6 adopt: $(lm | wc -w)"

echo "A7: a stopped machine is reused"
fresh $NOW0; listing "fixturestop1:stopped:$((NOW0 - 5000))"; tick
grep -q 'machine start fixturestop1 -a lane-run' "$FX/fly.argv" && ok "A7 machine start of the stopped machine" || bad "A7 argv: $(cat "$FX/fly.argv")"
[ "$(nfly 'machine run')" = 0 ] && ok "A7 no machine run" || bad "A7 ran"
[ "$(lm)" = "fixturestop1=starting " ] && ok "A7 row starting" || bad "A7 rows: $(lm)"

# ============================================================================
echo "C1: a Fly started machine with no row, 30 s old -> counted in flight"
fresh $NOW0; listing "fixturelost1:started:$((NOW0 - 30))"; queued 300; tick
[ "$(nfly 'machine run')" = 0 ] && ok "C1 no start" || bad "C1 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"live=0 inflight=1"*"none start-in-flight"*) ok "C1 log: inflight=1" ;; *) bad "C1 log: $LAST" ;; esac
[ "$(lm)" = "fixturelost1=starting " ] && ok "C1 adopted as starting" || bad "C1 rows: $(lm)"

echo "C2: wait 300 at max 2 with 2 idle machines -> no start, no stop"
fresh $NOW0; setting lane_fleet.max_machines 2
row fixturem0001 started $((NOW0 - 5000)); row fixturem0002 started $((NOW0 - 5000))
listing "fixturem0001:started:$((NOW0 - 5000))" "fixturem0002:started:$((NOW0 - 5000))"; queued 300; tick
[ "$(grep -cE 'machine (run|start|stop)' "$FX/fly.argv")" = 0 ] && ok "C2 no run, start or stop" || bad "C2 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"max=2 action=none at-max"*) ok "C2 log: at-max" ;; *) bad "C2 log: $LAST" ;; esac

echo "C3: max_machines 'abc' / ' 0 ' -> no ceiling"
for v in abc ' 0 '; do
  fresh $NOW0; setting lane_fleet.max_machines "$v"; row fixturelive1 started $((NOW0 - 1000))
  listing "fixturelive1:started:$((NOW0 - 1000))"; queued 300; tick
  [ "$(nfly 'machine run')" = 1 ] && ok "C3 max_machines '$v' starts the 2nd machine" || bad "C3 '$v' log: $LAST"
done

# ============================================================================
echo "F1: lock held -> no flyctl call"
fresh $NOW0; queued 300
exec 8>"$H/locks/lane-fleet.lock"; flock 8; tick; exec 8>&-
[ ! -s "$FX/fly.argv" ] && ok "F1 no flyctl call" || bad "F1 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"lock held"*) ok "F1 log: lock held" ;; *) bad "F1 log: $LAST" ;; esac

echo "F2: JOBS_URL empty -> no flyctl call"
fresh $NOW0; JOBS_URL="" bash "$H/bin/lane-fleet.sh" tick; rc=$?
[ "$rc" = 0 ] && [ ! -s "$FX/fly.argv" ] && ok "F2 rc 0, no flyctl call" || bad "F2 rc=$rc argv: $(cat "$FX/fly.argv")"
grep -q 'not configured' "$H/logs/lane-fleet.log" && ok "F2 log: not configured" || bad "F2 log: $(cat "$H/logs/lane-fleet.log")"

echo "F3: stats answers 500 -> no start, one ALERTS line"
fresh $NOW0; queued 300; curl -sS -X PUT "$JOBS_URL/__fail" -d '{"path":"/api/lane-runs/stats","n":2}' >/dev/null
tick; tick
[ "$(nfly 'machine run')" = 0 ] && ok "F3 no machine run" || bad "F3 argv: $(cat "$FX/fly.argv")"
[ "$(nalerts 'stats read failed')" = 1 ] && ok "F3 one ALERTS line over two ticks" || bad "F3 alerts: $(cat "$H/logs/ALERTS.log")"

echo "F4: machine run prints no Machine ID -> no row, one ALERTS line"
fresh $NOW0; queued 300; printf 'Error: fixture capacity\n' > "$FX/run.out"
tick; tick
[ "$(nfly 'machine run')" = 2 ] && ok "F4 retried next tick" || bad "F4 argv: $(cat "$FX/fly.argv")"
[ -z "$(lm)" ] && ok "F4 no lane_machines row" || bad "F4 rows: $(lm)"
[ "$(nalerts 'gave no machine id')" = 1 ] && ok "F4 one ALERTS line over two ticks" || bad "F4 alerts: $(cat "$H/logs/ALERTS.log")"

echo "F5: reuse fails -> destroy --force, not found = gone"
fresh $NOW0; listing "fixturestop1:stopped:$((NOW0 - 5000))"; touch "$FX/start.fail"
echo "Error: machine fixturestop1 not found" > "$FX/destroy.out"; echo 1 > "$FX/destroy.rc"
tick
grep -q 'machine destroy fixturestop1 -a lane-run --force' "$FX/fly.argv" && ok "F5 machine destroy --force" || bad "F5 argv: $(cat "$FX/fly.argv")"
[ "$(nfly 'machine run')" = 0 ] && ok "F5 no start this tick" || bad "F5 ran"
[ "$(lm)" = "fixturestop1=destroyed " ] && ok "F5 not found counts as gone" || bad "F5 rows: $(lm)"
[ "$(grep -c . "$H/logs/ALERTS.log")" = 0 ] && ok "F5 no alert for a gone machine" || bad "F5 alerts: $(cat "$H/logs/ALERTS.log")"

echo "R1: a started row whose machine Fly lists stopped is reconciled"
fresh $NOW0; row fixturem0001 started $((NOW0 - 5000)); row fixturem0002 started $((NOW0 - 5000))
listing "fixturem0001:started:$((NOW0 - 5000))" "fixturem0002:stopped:$((NOW0 - 100))"; tick
[ "$(lm)" = "fixturem0001=started fixturem0002=stopped " ] && ok "R1 row stopped" || bad "R1 rows: $(lm)"

# ============================================================================
echo "G1: a reused machine is in flight until it claims again"
fresh $NOW0
row fixturereu01 started $((NOW0 - 4000))
sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, status, finished_at, rc)
     VALUES ('alpha','p0','[\"bin/x.sh\"]',?,?,'fixturereu01','done',?,0)" "$(iso $((NOW0 - 3970)))" "$(iso $((NOW0 - 3970)))" "$(iso $((NOW0 - 3900)))" >/dev/null
api POST /api/lane-fleet/machines '{"machine_id":"fixturereu01","state":"stopped"}' >/dev/null
listing "fixturereu01:stopped:$((NOW0 - 3000))"; queued 300; tick
grep -q 'machine start fixturereu01 -a lane-run' "$FX/fly.argv" && ok "G1 the stopped machine is reused" || bad "G1 argv: $(cat "$FX/fly.argv")"
clock $((NOW0 + 30)); listing "fixturereu01:started:$((NOW0 + 5))"; : > "$FX/fly.argv"; tick
[ "$(grep -cE 'machine (run|start)' "$FX/fly.argv")" = 0 ] && ok "G1 the next tick starts nothing" || bad "G1 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"inflight=1"*"action=none start-in-flight"*) ok "G1 log: the reuse is in flight" ;; *) bad "G1 log: $LAST" ;; esac
[ "$(lm)" = "fixturereu01=starting " ] && ok "G1 an old claim does not promote the row" || bad "G1 rows: $(lm)"

echo "G2: a start past grace that Fly still runs, no claim, wait 300"
fresh $NOW0; row fixturedead1 starting $((NOW0 - 200)); listing "fixturedead1:started:$((NOW0 - 200))"; queued 300; tick
[ "$(grep -cE 'machine (run|start)' "$FX/fly.argv")" = 0 ] && ok "G2 no machine run or start" || bad "G2 argv: $(cat "$FX/fly.argv")"
grep -q 'machine stop fixturedead1 -a lane-run' "$FX/fly.argv" && ok "G2 the dead start is stopped" || bad "G2 argv: $(cat "$FX/fly.argv")"
[ "$(lm)" = "fixturedead1=stopped " ] && ok "G2 its row is stopped" || bad "G2 rows: $(lm)"
f=$(sql "SELECT failed_at FROM lane_machines WHERE machine_id='fixturedead1'" | jq -r '.rows[0].failed_at')
[ "$f" = "$(iso $NOW0)" ] && ok "G2 failed_at is set" || bad "G2 failed_at: $f"
[ "$(nalerts 'start fixturedead1 made no claim')" = 1 ] && ok "G2 one ALERTS line" || bad "G2 alerts: $(cat "$H/logs/ALERTS.log")"
case "$LAST" in *"action=none failed-start-hold"*) ok "G2 log: failed-start-hold" ;; *) bad "G2 log: $LAST" ;; esac
clock $((NOW0 + 60)); listing "fixturedead1:stopped:$((NOW0 + 1))"; : > "$FX/fly.argv"; tick
[ "$(grep -cE 'machine (run|start)' "$FX/fly.argv")" = 0 ] && ok "G2 the next tick holds (backoff)" || bad "G2 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"action=none failed-start-hold"*) ok "G2 log: still held" ;; *) bad "G2 log: $LAST" ;; esac

echo "G3: a start that exits at boot is not restarted every minute"
fresh $NOW0; queued 300; tick
[ "$(nfly 'machine run')" = 1 ] && ok "G3 t0 one machine run" || bad "G3 argv: $(cat "$FX/fly.argv")"
for i in 1 2 3 4 5 6; do clock $((NOW0 + 60 * i)); listing "fixturenew01:stopped:$((NOW0 + 20))"; tick; done
[ "$(nfly 'machine start')" = 0 ] && [ "$(nfly 'machine run')" = 1 ] && ok "G3 no restart in 6 ticks" || bad "G3 argv: $(cat "$FX/fly.argv")"
[ "$(nalerts 'start fixturenew01 made no claim')" = 1 ] && ok "G3 one ALERTS line" || bad "G3 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(lm)" = "fixturenew01=stopped " ] && ok "G3 its row is stopped" || bad "G3 rows: $(lm)"
n=$(sql "SELECT COUNT(*) AS n FROM cost_rows WHERE box='lane-run-fixturenew01'" | jq '.rows[0].n')
[ "$n" = 1 ] && ok "G3 its boot minute is billed (1 row)" || bad "G3 cost rows: $n"
clock $((NOW0 + 60 + 900)); tick
grep -q 'machine start fixturenew01 -a lane-run' "$FX/fly.argv" && ok "G3 after the backoff the reuse runs" || bad "G3 argv: $(cat "$FX/fly.argv")"

echo "G4: a queued run under the threshold, 2 idle machines -> no stop"
fresh $NOW0
row fixturem0001 started $((NOW0 - 5000)); row fixturem0002 started $((NOW0 - 5000))
listing "fixturem0001:started:$((NOW0 - 5000))" "fixturem0002:started:$((NOW0 - 5000))"; queued 30; tick
[ "$(nfly 'machine stop')" = 0 ] && ok "G4 no stop while a run is queued" || bad "G4 argv: $(cat "$FX/fly.argv")"
case "$LAST" in *"wait=30 "*"action=none wait-under-threshold"*) ok "G4 log: none" ;; *) bad "G4 log: $LAST" ;; esac

echo "G5: reconcile bills up to Fly's stop time"
fresh $((T0 + 3600)); setting lane_fleet.warm_floor 0; row fixturerec01 started "$T0"; listing "fixturerec01:stopped:$((T0 + 120))"; tick
n=$(sql "SELECT COUNT(*) AS n FROM cost_rows WHERE box='lane-run-fixturerec01'" | jq '.rows[0].n')
[ "$n" = 2 ] && ok "G5 2 rows, not 60" || bad "G5 cost rows: $n"
s=$(sql "SELECT state, stopped_at FROM lane_machines WHERE machine_id='fixturerec01'" | jq -r '.rows[0] | "\(.state) \(.stopped_at)"')
[ "$s" = "stopped $(iso $((T0 + 120)))" ] && ok "G5 stopped_at is Fly's stop time" || bad "G5 row: $s"

echo "G6: lane_fleet.image is pinned to registry.fly.io/lane-run"
fresh $NOW0; setting lane_fleet.image evil.example/x:latest; queued 300; tick
grep 'machine run' "$FX/fly.argv" | grep -q '^machine run registry.fly.io/lane-run:latest ' && ok "G6 another registry uses the default" || bad "G6 argv: $(cat "$FX/fly.argv")"
fresh $NOW0; setting lane_fleet.image registry.fly.io/lane-run-evil:latest; queued 300; tick
grep 'machine run' "$FX/fly.argv" | grep -q '^machine run registry.fly.io/lane-run:latest ' && ok "G6 a look-alike repository uses the default" || bad "G6 argv: $(cat "$FX/fly.argv")"
fresh $NOW0; setting lane_fleet.image registry.fly.io/lane-run@sha256:0123abcd; queued 300; tick
grep 'machine run' "$FX/fly.argv" | grep -q '^machine run registry.fly.io/lane-run@sha256:0123abcd ' && ok "G6 a digest of the app image is used" || bad "G6 argv: $(cat "$FX/fly.argv")"

# ============================================================================
echo "F6: fly/lane-run-entrypoint.sh"
E="$T/eh"; mkdir -p "$E/bin/lib" "$E/env"
( cd "$REPO" && scratch_install_closure bin/lib/env-path.sh "$E" ) >/dev/null 2>&1 || bad "F6 setup: env-path.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$0" "$@" > "%s/exec.argv"\n' "$T" > "$E/bin/lane-run-worker.sh"; chmod +x "$E/bin/lane-run-worker.sh"
EP="$REPO/fly/lane-run-entrypoint.sh"
env -i PATH="$PATH" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-secret-value-6126 JOBS_URL=http://192.0.2.1 \
  FLY_MACHINE_ID=fixturemid01 GH_APP_ID=12345 GH_APP_PRIVATE_KEY=fixture-pem-text-6126 GH_APP_INSTALLATION_FIXTURE=99 \
  bash "$EP" > "$T/ep.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F6 rc 0 (exec'd the stub)" || bad "F6 rc=$rc: $(cat "$T/ep.out")"
[ "$(tr '\n' ' ' < "$T/exec.argv")" = "$E/bin/lane-run-worker.sh --machine fixturemid01 " ] && ok "F6 exec argv" || bad "F6 argv: $(cat "$T/exec.argv")"
for f in global.env github-app.env github-app.pem; do
  [ "$(stat -c %a "$E/env/$f" 2>/dev/null)" = 600 ] && ok "F6 $f mode 600" || bad "F6 $f mode: $(stat -c %a "$E/env/$f" 2>&1)"
done
grep -qx 'HARNESS_SECRET=fixture-secret-value-6126' "$E/env/global.env" && ok "F6 global.env carries the secret" || bad "F6 global.env"
grep -qx "GH_APP_PRIVATE_KEY_FILE=$E/env/github-app.pem" "$E/env/github-app.env" && grep -qx 'GH_APP_INSTALLATION_FIXTURE=99' "$E/env/github-app.env" \
  && ok "F6 github-app.env names the key file and the installation" || bad "F6 github-app.env: $(cat "$E/env/github-app.env")"
grep -q 'fixture-secret-value-6126\|fixture-pem-text-6126' "$T/ep.out" && bad "F6 a secret reached the output" || ok "F6 no secret in stdout/stderr"
env -i PATH="$PATH" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" JOBS_URL=http://192.0.2.1 FLY_MACHINE_ID=fixturemid01 \
  bash "$EP" > "$T/ep2.out" 2>&1; rc=$?
[ "$rc" = 78 ] && grep -q 'HARNESS_SECRET is not set' "$T/ep2.out" && ok "F6 exit 78 without HARNESS_SECRET, naming it" || bad "F6 rc=$rc: $(cat "$T/ep2.out")"
TOML="$REPO/fly/lane-run.toml"
grep -qx 'app = "lane-run"' "$TOML" && df=$(sed -n 's/^ *dockerfile = "\(.*\)"$/\1/p' "$TOML") && [ -f "$REPO/fly/$df" ] \
  && ok "F6 fly/lane-run.toml: app lane-run, its Dockerfile exists" || bad "F6 toml: $(cat "$TOML")"
grep -q '^ENTRYPOINT .*/opt/lane-run/entrypoint.sh' "$REPO/fly/lane-run.Dockerfile" && grep -q '^COPY fly/lane-run-entrypoint.sh /opt/lane-run/entrypoint.sh$' "$REPO/fly/lane-run.Dockerfile" \
  && ok "F6 the image runs the entrypoint" || bad "F6 Dockerfile entrypoint"
[ "$(grep -c 'HARNESS_SECRET\|PRIVATE_KEY' "$REPO/fly/lane-run.Dockerfile")" = 0 ] && ok "F6 the Dockerfile names no secret" || bad "F6 Dockerfile names a secret"

echo "H1: the warm floor holds with an empty queue"
fresh $NOW0; tick
[ "$(nfly 'machine run')" = 1 ] && ok "H1 t0 one machine run (below floor)" || bad "H1 argv: $(cat "$FX/fly.argv")"
for i in $(seq 1 25); do clock $((NOW0 + 60 * i)); listing "fixturenew01:started:$((NOW0 + 10))"; tick; done
[ "$(nfly 'machine run')" = 1 ] && [ "$(nfly 'machine start')" = 0 ] && ok "H1 25 ticks: no second start" || bad "H1 argv: $(cat "$FX/fly.argv")"
[ "$(nfly 'machine stop')" = 0 ] && ok "H1 25 ticks: no stop" || bad "H1 argv: $(cat "$FX/fly.argv")"
[ "$(nalerts 'made no claim')" = 0 ] && ok "H1 no ALERTS line" || bad "H1 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(lm)" = "fixturenew01=started " ] && ok "H1 the row is promoted to started" || bad "H1 rows: $(lm)"
case "$LAST" in *"live=1 inflight=0"*"action=none wait-under-threshold"*) ok "H1 log: live 1 at the floor" ;; *) bad "H1 log: $LAST" ;; esac

echo "H2: a busy starting row is never a failed start"
fresh $NOW0; row fixturereu01 starting $((NOW0 - 200)); listing "fixturereu01:started:$((NOW0 - 200))"
sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, status, lease_until)
     VALUES ('alpha','p0','[\"bin/x.sh\"]',?,?,'fixturereu01','claimed',?)" "$(iso $((NOW0 - 210)))" "$(iso $((NOW0 - 203)))" "$(iso $((NOW0 + 700)))" >/dev/null
tick
[ "$(nfly 'machine stop')" = 0 ] && ok "H2 the busy machine is not stopped" || bad "H2 argv: $(cat "$FX/fly.argv")"
[ "$(nalerts 'made no claim')" = 0 ] && ok "H2 no ALERTS line" || bad "H2 alerts: $(cat "$H/logs/ALERTS.log")"
case "$LAST" in *"failed-start-hold"*) bad "H2 log: $LAST" ;; *) ok "H2 no failed-start hold" ;; esac

echo "H3: a start is recorded at the tick's decision time"
fresh $NOW0; queued 300
curl -sS -X PUT "$JOBS_URL/__clock" -d "{\"epoch\":$((NOW0 + 7))}" >/dev/null
tick
s=$(sql "SELECT started_at FROM lane_machines WHERE machine_id='fixturenew01'" | jq -r '.rows[0].started_at')
[ "$s" = "$(iso $NOW0)" ] && ok "H3 started_at is the tick time" || bad "H3 started_at: $s (tick $(iso $NOW0))"

echo
echo "lane-fleet.bh-6126: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
