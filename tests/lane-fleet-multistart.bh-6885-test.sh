#!/bin/bash
# tests/lane-fleet-multistart.bh-6885-test.sh — BH-6885 (BH-6881.7): the
# lane-run fleet starts several machines per tick, sized by queued work, and a
# machine's claim prefers the projects it has warm clones of.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs, worker clock pinned), with a stub
# flyctl on LANE_FLEET_FLY that logs its argv and gives each `machine run` its
# own Machine ID. The node half (tests/lib/lane-runs-claim-prefer.bh-6885.mjs)
# drives the claim and stats routes and the query plans.
#
#   M1-M12  lf_decide: start count by queued work, the floor, the hold, max
#   N       the node half: S1, P1-P10, R1-R5, E1-E3 (rc 3 = visible SKIP)
#   T1  40 queued x 30 s, live 2: 5 machine run, 5 rows starting, one log line
#   T2  target_drain_s 5 (out of range) = 60: 5 starts; max_starts_per_tick 2: 2
#   T3  the 3rd machine run gives no Machine ID: 2 starts, the batch stops, rc 0
#   T4  empty queue, live 3 > floor 1: one stop (the stop rule is unchanged)
#   T5  2 stopped machines, desired 4: 2 machine start (sorted), then 2 run
#   C1  the worker claims its cached project first (prefer)
#   C2  no clone dir: the claim works, nothing is evicted
#   C3  10 clones, clone_cache_n 8, LANE_RUN=1: the 2 oldest are evicted
#   C4  the same without LANE_RUN: nothing is evicted
#   C5  exactly 8 clones: nothing is evicted
#   C5b the run's own clone is the oldest: it is touched and kept
#   C6  a symlink, a dir with no .git and a bad name: never listed, never removed
#
# Run from anywhere: tests/lane-fleet-multistart.bh-6885-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/lane-fleet-worker.bh-6126.mjs"
NODE_HALF="$REPO/tests/lib/lane-runs-claim-prefer.bh-6885.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# The worker imports these git-ignored catalogs (BH-6540); CI renders them, a
# local run renders them here.
"$REPO/bin/lanes-build.sh" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$T/fx"
printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"
for L in bin/lane-fleet.sh bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null

# ============================================================================
echo "M: lf_decide"
( . "$H/bin/lane-fleet.sh"
  # chk <want> <W> <LIVE> <INFLIGHT> <FLOOR> <UPWAIT> <MAX> [HOLD WORK_S TARGET_S MAXSTARTS]
  chk() { local id="$1" want="$2" got; shift 2; got=$(lf_decide "$@")
    [ "$got" = "$want" ] && echo "ok $id lf_decide $* -> $got" || echo "FAIL $id lf_decide $* -> '$got' (want '$want')"; }
  chk M1 "start 5 queue-depth" 10 2 0 1 60 0 0 1200 60 5           # 40 x 30 s, live 2
  chk M2 "none wait-under-threshold" 10 2 0 1 60 0 0 30 60 5       # 1 x 30 s, live 2
  chk M3 "none failed-start-hold" 10 2 0 1 60 0 1 1200 60 5        # inside the backoff
  chk M4 "start 5 queue-depth" 10 2 0 1 60 0 0 600 60 5            # desired 10, capped 5
  chk M5 "start 3 below-floor" none 0 0 3 60 0 0 0 60 5            # floor 3, live 0
  chk M6 "start 1 queue-wait" 300 2 0 1 60 0 0 0 60 5              # wait over, no sample
  chk M7 "start 1 queue-depth" 10 2 0 1 60 0 0 121 60 5            # desired 3 (ceil)
  chk M8 "none wait-under-threshold" 10 2 0 1 60 0 0 120 60 5      # desired 2 = live
  chk M9 "none start-in-flight" 300 2 1 1 60 0 0 1200 60 5
  chk M10 "none at-max" 300 4 0 1 60 4 0 1200 60 5
  chk M11 "start 2 queue-depth" 10 2 0 1 60 4 0 1200 60 5          # max 4 leaves room for 2
  chk M12 "start 1 queue-wait" 300 1 0 1 60 0 0                    # the 7-arg call
  chk M12b "start 1 below-floor" none 0 0 3 60 0                   # 7-arg default: one start
  chk M12c "start 1 queue-depth" 10 2 0 1 60 0 0 1200 60 1         # max-starts 1
) > "$T/m.out" 2>&1
while IFS= read -r l; do case "$l" in ok*) ok "${l#ok }" ;; *) bad "${l#FAIL }" ;; esac; done < "$T/m.out"
[ "$(grep -c '^ok' "$T/m.out")" = 14 ] && ok "M all 14 rows ran" || bad "M rows: $(cat "$T/m.out")"

# ============================================================================
echo "N: claim prefer, stats run_p50, seeds and query plans (node half)"
node "$NODE_HALF" > "$T/n.out" 2>&1; nrc=$?
if [ "$nrc" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
while IFS= read -r l; do case "$l" in ok*) ok "N ${l#ok }" ;; *) bad "N ${l#FAIL }" ;; esac; done < "$T/n.out"
[ "$nrc" = 0 ] && ok "N rc 0" || bad "N rc $nrc"

# ============================================================================
# The stub flyctl: argv to fx/fly.argv; each `machine run` prints its own id,
# fixturerun0<n>, except the run named in fx/run.failat (no Machine ID).
FX="$T/fx"
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
case "\$1 \$2" in
  "machine list") cat "$FX/list.json" ;;
  "machine run") n=\$(( \$(cat "$FX/run.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$FX/run.n"
                 if [ "\$n" = "\$(cat "$FX/run.failat" 2>/dev/null)" ]; then echo "Error: fixture run failure"; exit 1; fi
                 printf 'Machine ID: fixturerun0%s\nState: created\n' "\$n" ;;
  "machine start") echo "fixture started" ;;
  "machine stop") echo "fixture stopped" ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub FLEET_CONF="$H/fleet.conf"
export GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl"
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0 LANE_RUN_NOW=$NOW0

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
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list.json"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; : > "$H/logs/lane-run-worker.log"; rm -f "$H/flags/"alerted-lane-fleet-*
}
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
row() { api POST /api/lane-fleet/machines "$(jq -nc --arg m "$1" --arg s "$2" --arg a "$(iso "$3")" \
  '{machine_id:$m, state:$s, started_at:$a, cpu_kind:"shared", cpus:2, memory_mb:2048}')" >/dev/null; }
listing() { local a out="[]" id st up
  for a in "$@"; do IFS=: read -r id st up <<<"$a"
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso "$up")" \
      '. + [{id:$i, state:$s, created_at:$u, updated_at:$u, config:{image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:"shared", cpus:2, memory_mb:2048}}}]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list.json"; }
# queue <lane> <n> <seconds ago> — n queued rows, projects q1..q<n>.
queue() { local i; for i in $(seq 1 "$2"); do
  sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES (?,?,'[\"bin/fake-lane.sh\"]',?,'queued')" "$1" "q$i" "$(iso $((NOW - $3)))" >/dev/null; done; }
# done_rows <lane> <n> <run seconds> — n done rows, each run <run seconds> long.
done_rows() { local i; for i in $(seq 1 "$2"); do
  sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, finished_at, status, rc) VALUES (?,?,'[\"bin/x.sh\"]',?,?,?,'done',0)" \
    "$1" "d$i" "$(iso $((NOW - 5000)))" "$(iso $((NOW - 4000)))" "$(iso $((NOW - 4000 + $3)))" >/dev/null; done; }
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; SUM=$(grep 'tick wait=' "$H/logs/lane-fleet.log" | tail -n 1); }
nfly() { grep -c -- "$1" "$FX/fly.argv"; }
nstarting() { sql "SELECT COUNT(*) AS n FROM lane_machines WHERE state='starting'" | jq '.rows[0].n'; }
live2() { row fixturelive1 started $((NOW0 - 100)); row fixturelive2 started $((NOW0 - 100))
  listing "fixturelive1:started:$((NOW0 - 100))" "fixturelive2:started:$((NOW0 - 100))"; }

# ============================================================================
echo "T1: 40 queued x 30 s p50, live 2 -> 5 starts"
fresh $NOW0; live2; queue L 40 10; done_rows L 50 30; tick
[ "$TRC" = 0 ] && ok "T1 tick rc 0" || bad "T1 rc $TRC"
[ "$(grep -cE -- 'machine run .* --app lane-run ' "$FX/fly.argv")" = 5 ] && ok "T1 5 machine run" || bad "T1 argv: $(cat "$FX/fly.argv")"
[ "$(nstarting)" = 5 ] && ok "T1 5 rows starting" || bad "T1 starting: $(nstarting)"
case "$SUM" in *"action=start fixturerun01,fixturerun02,fixturerun03,fixturerun04,fixturerun05 queue-depth cost="*) ok "T1 log: the 5 ids, queue-depth" ;; *) bad "T1 log: $SUM" ;; esac
case "$SUM" in *" work=1200s desired=20") ok "T1 log: work=1200s desired=20" ;; *) bad "T1 log: $SUM" ;; esac
grep -q 'GET /api/lane-runs/stats?run_p50=1 200' "$T/w1.log" && ok "T1 the tick reads stats?run_p50=1" || bad "T1 reads: $(grep stats "$T/w1.log")"

echo "T2: target_drain_s 5 is out of range (default 60); max_starts_per_tick 2"
fresh $NOW0; live2; queue L 40 10; done_rows L 50 30; setting lane_fleet.target_drain_s 5; tick
[ "$(nfly 'machine run')" = 5 ] && ok "T2 target 5 -> default 60 -> 5 starts" || bad "T2 runs: $(nfly 'machine run')"
case "$SUM" in *" desired=20") ok "T2 desired=20 (target 60)" ;; *) bad "T2 log: $SUM" ;; esac
fresh $NOW0; live2; queue L 40 10; done_rows L 50 30; setting lane_fleet.max_starts_per_tick 2; tick
[ "$(nfly 'machine run')" = 2 ] && ok "T2 max_starts_per_tick 2 -> 2 starts" || bad "T2 runs: $(nfly 'machine run')"
fresh $NOW0; live2; queue L 40 10; done_rows L 50 30; setting lane_fleet.target_drain_s 600; tick
[ "$(nfly 'machine run')" = 0 ] && ok "T2 target_drain_s 600 -> desired 2 = live, no start" || bad "T2 runs: $(nfly 'machine run')"

echo "T3: the 3rd machine run gives no Machine ID"
fresh $NOW0; live2; queue L 40 10; done_rows L 50 30; echo 3 > "$FX/run.failat"; tick
[ "$TRC" = 0 ] && ok "T3 tick rc 0" || bad "T3 rc $TRC"
[ "$(nfly 'machine run')" = 3 ] && ok "T3 the batch stops at the failure (3 calls, not 5)" || bad "T3 runs: $(nfly 'machine run')"
[ "$(nstarting)" = 2 ] && ok "T3 2 rows starting" || bad "T3 starting: $(nstarting)"
grep -q 'start batch stopped after 2 of 5' "$H/logs/lane-fleet.log" && ok "T3 log: start batch stopped after 2 of 5" || bad "T3 log: $(cat "$H/logs/lane-fleet.log")"
case "$SUM" in *"action=start fixturerun01,fixturerun02 queue-depth"*) ok "T3 action names the 2 started" ;; *) bad "T3 log: $SUM" ;; esac
[ "$(grep -c 'gave no machine id' "$H/logs/ALERTS.log")" = 1 ] && ok "T3 one ALERTS line" || bad "T3 alerts: $(cat "$H/logs/ALERTS.log")"

echo "T4: empty queue, live 3 > floor 1, one idle machine -> one stop"
fresh $NOW0
row fixturem0001 started $((NOW0 - 100)); row fixturem0002 started $((NOW0 - 100)); row fixturem0003 started $((NOW0 - 900))
listing "fixturem0001:started:$((NOW0 - 100))" "fixturem0002:started:$((NOW0 - 100))" "fixturem0003:started:$((NOW0 - 900))"
done_rows L 50 30; tick
[ "$(nfly 'machine stop')" = 1 ] && grep -q 'machine stop fixturem0003 -a lane-run' "$FX/fly.argv" && ok "T4 one stop, the idle machine" || bad "T4 argv: $(cat "$FX/fly.argv")"
[ "$(grep -cE 'machine (run|start)' "$FX/fly.argv")" = 0 ] && ok "T4 no start" || bad "T4 argv: $(cat "$FX/fly.argv")"
case "$SUM" in *"action=stop fixturem0003 idle=900 cost="*" work=0s desired=0") ok "T4 log: stop idle=900, work=0s" ;; *) bad "T4 log: $SUM" ;; esac

echo "T5: 2 stopped machines, desired 4 -> 2 machine start, then 2 machine run"
fresh $NOW0; listing "fixturestop2:stopped:$((NOW0 - 5000))" "fixturestop1:stopped:$((NOW0 - 5000))"
queue L 4 10; done_rows L 10 60; tick
grep -E 'machine (start|run)' "$FX/fly.argv" | awk '{print $2, $3}' > "$T/t5.seq"
[ "$(tr '\n' ' ' < "$T/t5.seq")" = "start fixturestop1 start fixturestop2 run registry.fly.io/lane-run:latest run registry.fly.io/lane-run:latest " ] \
  && ok "T5 start stop1, start stop2, then 2 run" || bad "T5 seq: $(cat "$FX/fly.argv")"
[ "$(nstarting)" = 4 ] && ok "T5 4 rows starting" || bad "T5 starting: $(nstarting)"
case "$SUM" in *"action=start fixturestop1,fixturestop2,fixturerun01,fixturerun02 below-floor"*) ok "T5 log: the 4 ids" ;; *) bad "T5 log: $SUM" ;; esac

# ============================================================================
# The worker cases: the real bin/lane-run-worker.sh --once against the same
# worker. The fake lane writes one line per run: <project>.
for p in A B C P g9 S nogit zz r01 r02 r03 r04 r05 r06 r07 r08 r09 r10; do printf '%s o/%s - - 2 box-%s 192.0.2.1\n' "$p" "$p" "$p"; done > "$H/fleet.conf"
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
echo "\${@: -1}" >> "$T/runs.txt"
exit 0
EOF
chmod +x "$H/bin/fake-lane.sh"
R="$T/repos"
# clones <name:epoch> ... — fresh \$R with one git clone dir per name, mtime epoch.
clones() { local a; [ ! -e "$R" ] || scratch_rm "$R" || exit 1; mkdir -p "$R"
  for a in "$@"; do mkdir -p "$R/${a%%:*}/.git"; touch -d "@${a##*:}" "$R/${a%%:*}"; done; }
qrow() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES ('demo',?,'[\"bin/fake-lane.sh\"]',?,'queued')" "$1" "$(iso $((NOW - $2)))" >/dev/null; }
work() { : > "$T/runs.txt"; env REPOS_ROOT="$R" "$@" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/wk.out" 2>&1; WRC=$?; }
left() { ( cd "$R" && ls -1A | tr '\n' ' ' ); }
nevict() { grep -c 'clone cache: evicted' "$H/logs/lane-run-worker.log"; }

echo "C1: the worker claims its cached project first"
fresh $NOW0; clones C:1000 A:2000; qrow B 30; qrow A 10; work
[ "$WRC" = 0 ] && ok "C1 worker rc 0" || bad "C1 rc $WRC: $(cat "$T/wk.out")"
[ "$(tr '\n' ' ' < "$T/runs.txt")" = "A B " ] && ok "C1 A (cached) ran before B (older)" || bad "C1 order: $(tr '\n' ' ' < "$T/runs.txt")"
[ "$(left)" = "A C " ] && ok "C1 2 clones under the cap stay" || bad "C1 left: $(left)"

echo "C2: no clone dir"
fresh $NOW0; [ ! -e "$R" ] || scratch_rm "$R" || exit 1; qrow B 30; qrow A 10; work
[ "$WRC" = 0 ] && [ "$(tr '\n' ' ' < "$T/runs.txt")" = "B A " ] && ok "C2 the oldest first, rc 0" || bad "C2 rc $WRC order: $(cat "$T/runs.txt")"
[ "$(grep -c 'POST /api/lane-runs/claim 200' "$T/w${#PIDS[@]}.log")" = 2 ] && ok "C2 2 claims answered 200" || bad "C2 log: $(cat "$T/w${#PIDS[@]}.log")"
[ ! -e "$R" ] && [ "$(nevict)" = 0 ] && ok "C2 nothing created, nothing evicted" || bad "C2 $(ls "$R" 2>&1) $(nevict)"

ten() { clones r01:1001 r02:1002 r03:1003 r04:1004 r05:1005 r06:1006 r07:1007 r08:1008 r09:1009 r10:1010; }
echo "C3: 10 clones, clone_cache_n 8, LANE_RUN=1 -> the 2 oldest evicted"
fresh $NOW0; setting lane_run.clone_cache_n 8; ten; qrow zz 10; work LANE_RUN=1
[ "$(left)" = "r03 r04 r05 r06 r07 r08 r09 r10 " ] && ok "C3 r01 and r02 evicted, 8 stay" || bad "C3 left: $(left)"
[ "$(nevict)" = 2 ] && grep -q 'clone cache: evicted r01 (keep 8)' "$H/logs/lane-run-worker.log" && ok "C3 2 evicted lines" || bad "C3 log: $(cat "$H/logs/lane-run-worker.log")"
fresh $NOW0; ten; qrow zz 10; work LANE_RUN=1
[ "$(left)" = "r03 r04 r05 r06 r07 r08 r09 r10 " ] && ok "C3 the seed row (8) gives the same" || bad "C3 seed left: $(left)"
fresh $NOW0; setting lane_run.clone_cache_n 0; ten; qrow zz 10; work LANE_RUN=1
[ "$(left)" = "r03 r04 r05 r06 r07 r08 r09 r10 " ] && ok "C3 clone_cache_n 0 is out of range: default 8, not 0" || bad "C3 n=0 left: $(left)"

echo "C4: the same without LANE_RUN=1 -> nothing evicted"
fresh $NOW0; setting lane_run.clone_cache_n 8; ten; qrow zz 10; work
[ "$(left | wc -w)" = 10 ] && [ "$(nevict)" = 0 ] && ok "C4 10 stay" || bad "C4 left: $(left)"
fresh $NOW0; ten; qrow zz 10; work LANE_RUN=yes
[ "$(left | wc -w)" = 10 ] && ok "C4 LANE_RUN=yes is not 1: 10 stay" || bad "C4 yes left: $(left)"

echo "C5: exactly 8 clones -> nothing evicted"
fresh $NOW0; clones r01:1001 r02:1002 r03:1003 r04:1004 r05:1005 r06:1006 r07:1007 r08:1008; qrow zz 10; work LANE_RUN=1
[ "$(left | wc -w)" = 8 ] && [ "$(nevict)" = 0 ] && ok "C5 8 stay" || bad "C5 left: $(left)"

echo "C5b: 9 clones, the run's own clone is the oldest -> it stays"
fresh $NOW0; clones r01:1001 r02:1002 r03:1003 r04:1004 r05:1005 r06:1006 r07:1007 r08:1008 r09:1009; qrow r01 10; work LANE_RUN=1
[ "$(left)" = "r01 r03 r04 r05 r06 r07 r08 r09 " ] && ok "C5b r01 touched and kept, r02 evicted" || bad "C5b left: $(left)"

echo "C6: a symlink, a dir with no .git and a bad name are never listed or removed"
fresh $NOW0; setting lane_run.clone_cache_n 1
clones g1:3000 g2:1000; mkdir -p "$T/real/.git" "$R/nogit" "$R/bad name/.git"; ln -s "$T/real" "$R/S"
touch -d @5000 "$R/nogit" "$R/bad name"; touch -h -d @5000 "$R/S"
qrow g9 30; qrow S 10; qrow nogit 10; work LANE_RUN=1
[ "$(head -1 "$T/runs.txt")" = g9 ] && ok "C6 neither S nor nogit is preferred: g9 (oldest) first" || bad "C6 order: $(cat "$T/runs.txt")"
[ -L "$R/S" ] && [ -d "$T/real/.git" ] && [ -d "$R/nogit" ] && [ -d "$R/bad name/.git" ] && ok "C6 S, nogit, 'bad name' and the symlink target stay" || bad "C6 left: $(left)"
[ -d "$R/g1" ] && [ ! -e "$R/g2" ] && ok "C6 the real clones obey N 1: g1 stays, g2 evicted" || bad "C6 left: $(left)"

echo
echo "lane-fleet-multistart.bh-6885: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
