#!/bin/bash
# tests/project-lanes-fly.bh-6124-test.sh — BH-6124 (1 of 5, split from
# BH-6047): a lane placed `fly` is enqueued by pl_dispatch as a lane_runs row,
# and bin/lane-run-worker.sh claims it, runs it and reports its rc.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-runs-worker.bh-6124.mjs), through the real pl_dispatch
# (bin/lib/project-lanes.sh + bin/lib/lane-placement.sh), the real
# bin/project-lane-run.sh and the real bin/lane-run-worker.sh.
#
#   F1  lane_placement.demo=fly, 21 projects, 1 held: `placed: 20 fly, 0 hub`,
#       0 hub runs, 1 batch POST and 0 per-row POSTs (BH-6886), 20 queued
#       rows, none for the held one
#   F2  3 `lane-run-worker.sh --once` machines drain the 20 rows: every row
#       done with the fake lane's rc, claimer in {m1,m2,m3}, argv byte for
#       byte, PROF line stored, stats done=20 queued=0
#   F10 --once against an empty queue exits 0 fast and writes no row
#   F4  a hub_only text keeps the lane on the hub, and the line names it
#   F5  no lane row (default=hub seed): 20 hub runs, 0 enqueues, 0 alerts
#   F7  the adversarial placement table (lp_decide), one case via pl_dispatch
#   F6  a second dispatch while the rows are queued: 20 already live, 0 hub
#   F8  a worker with no batch route (NO_BATCH=1) takes the per-row path,
#       and 3 failed enqueues: 17 fly, 3 hub runs, ONE lane-placement alert
#   F11 a row whose command is missing is reported non-zero, never 0
#   F9  a closed worker port: hub for all, `settings unreadable`, no alert
#   F12 a command outside $H/bin stays on the hub, with the reason
#
# Run from anywhere: tests/project-lanes-fly.bh-6124-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/runs"
for L in bin/project-lane-run.sh bin/lib/project-lanes.sh bin/lane-run-worker.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
# The closure of the dispatcher and of the machine loop reaches every new lib,
# and the seams answer their contract (lrh_lost rc 1 = not lost).
for f in "$DIR/bin/lane-run-worker.sh" "$DIR/bin/lib/lane-placement.sh" \
         "$DIR/bin/lib/lane-run-heartbeat.sh" "$DIR/bin/lib/lane-run-inputs.sh"; do
  [ -f "$H/${f#"$DIR"/}" ] && ok "closure installs ${f#"$DIR"/}" || bad "closure lacks ${f#"$DIR"/}"
done
( . "$H/bin/lib/lane-run-heartbeat.sh" && . "$H/bin/lib/lane-run-inputs.sh" \
  && lrh_start 1 1 && lrh_stop && ! lrh_lost && lri_fetch demo p1 "$T" ) \
  && ok "seams: lrh_start/lrh_stop rc 0, lrh_lost rc 1, lri_fetch rc 0" || bad "seam stubs break their contract"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_RUN_NOW=1791000000
export BOX_NAME=fixture-box
# FLEET <n> — fleet.conf with projects p1..p<n>.
FLEET() { local i
  for i in $(seq 1 "$1"); do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$i" "$i" "$i" "$i"; done > "$H/fleet.conf"; }

# The fake lane: one line per run (<project> TAB <run id or hub>), its argv
# NUL-separated in runs/<project>.argv, a PROF line, and rc = <n> mod 3.
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
p="\${@: -1}"
printf '%s\t%s\n' "\$p" "\${LANE_RUN_ID:-hub}" >> "$T/runs.tsv"
printf '%s\0' "\$@" > "$T/runs/\$p.argv"
echo "PROF fake p=\$p ms=1"
exit \$(( \${p#p} % 3 ))
EOF
chmod +x "$H/bin/fake-lane.sh"

PIDS=()
# srv <name> [env...] -> PORT, or rc 3 (no node:sqlite)
srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
unsetting() { curl -sS -X DELETE "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" '{key:$k}')" >/dev/null; }
rows() { curl -sS "$JOBS_URL/__lane_runs"; }
nposts() { grep -c '^POST /api/lane-runs [0-9]' "$1" 2>/dev/null; }
nhub() { awk -F'\t' '$2 == "hub"' "$T/runs.tsv" 2>/dev/null | grep -c .; }
CLEAN() { : > "$T/runs.tsv"; rm -f "$T/runs/"*; : > "$H/logs/ALERTS.log"; }
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# dispatch <args> — pl_dispatch in THIS shell (not a $( ) subshell), so the
# hub runs it starts are this shell's jobs and wait_runs can wait for them.
dispatch() { pl_dispatch "$@" > "$T/dispatch.out"; DRC=$?; OUT=$(cat "$T/dispatch.out"); }
# wait_runs — wait for every hub run pl_dispatch started from this shell (its
# background children), never for the worker servers.
wait_runs() { local p; for p in $(jobs -p); do case " ${PIDS[*]} " in *" $p "*) ;; *) wait "$p" ;; esac; done; }
nalerts_lp() { grep -c 'lane-placement' "$H/logs/ALERTS.log" 2>/dev/null; }

# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || { echo "setup: project-lanes.sh did not load"; exit 1; }
lane_project_held() { [ "$2" = p21 ]; }

srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"
LOG1="$T/w1.log"

# ============================================================================
echo "F1: lane_placement.demo=fly -> 20 rows, 0 hub runs, held project skipped"
CLEAN; FLEET 21; setting lane_placement.demo fly
dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b"; rc=$DRC
[ "$rc" = 0 ] && ok "F1 pl_dispatch rc 0" || bad "F1 rc=$rc"
case "$OUT" in "demo dispatch: started 0 project run(s) (period 0s, no cap), 1 held: []"*) ok "F1 the existing summary prefix is unchanged" ;; *) bad "F1 prefix: $OUT" ;; esac
case "$OUT" in *"; placed: 20 fly, 0 hub (lane_placement.demo=fly)"*) ok "F1 placed: 20 fly" ;; *) bad "F1 summary: $OUT" ;; esac
wait_runs
[ "$(nhub)" = 0 ] && ok "F1 0 hub runs" || bad "F1 hub runs: $(nhub)"
[ "$(grep -c '^POST /api/lane-runs/batch 200$' "$LOG1")" = 1 ] && ok "F1 1 batch POST (BH-6886)" || bad "F1 batch posts: $(grep -c '^POST /api/lane-runs/batch' "$LOG1")"
[ "$(nposts "$LOG1")" = 0 ] && ok "F1 0 per-row enqueue POSTs" || bad "F1 per-row posts: $(nposts "$LOG1")"
R=$(rows)
[ "$(jq '[.rows[] | select(.status == "queued" and .lane == "demo")] | length' <<<"$R")" = 20 ] && ok "F1 20 queued rows" || bad "F1 rows: $R"
[ "$(jq '[.rows[] | select(.project == "p21")] | length' <<<"$R")" = 0 ] && ok "F1 the held project has no row" || bad "F1 held row"
[ "$(jq -c '.rows[0].args' <<<"$R")" = '["bin/fake-lane.sh","--x","a b"]' ] && ok "F1 args stored relative to the root" || bad "F1 args: $(jq -c '.rows[0].args' <<<"$R")"
[ "$(nalerts_lp)" = 0 ] && ok "F1 0 alerts" || bad "F1 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "F2: three --once machines drain the 20 rows"
for m in m1 m2 m3; do
  "$H/bin/lane-run-worker.sh" --once --machine "$m" > "$T/f2-$m.out" 2>&1 &
  eval "P_$m=\$!"
done
F2RC=""; for m in m1 m2 m3; do eval "wait \$P_$m"; F2RC="$F2RC $?"; done
[ "$F2RC" = " 0 0 0" ] && ok "F2 every --once loop exits 0" || bad "F2 rcs:$F2RC $(cat "$T"/f2-m*.out "$H/logs/lane-run-worker.log" 2>/dev/null | tail -5)"
R=$(rows)
NDONE=$(jq '[.rows[] | select(.status == "done")] | length' <<<"$R" 2>/dev/null)
[ "$NDONE" = 20 ] && ok "F2 20 rows done" || bad "F2 rows: $(jq -c '[.rows[] | {project,status,rc}]' <<<"$R")"
BADRC=$(jq -r '.rows[] | select((.rc|type) != "number" or .rc != ((.project | ltrimstr("p") | tonumber) % 3)) | .project' <<<"$R")
[ "$NDONE" = 20 ] && [ -z "$BADRC" ] && ok "F2 each rc is the fake lane's integer exit code" || bad "F2 rc wrong for: $BADRC"
[ "$NDONE" = 20 ] && [ -z "$(jq -r '.rows[] | select(.claimed_by | IN("m1","m2","m3") | not) | .id' <<<"$R")" ] && ok "F2 every claimer is m1, m2 or m3" || bad "F2 claimers: $(jq -c '[.rows[].claimed_by]' <<<"$R")"
[ "$NDONE" = 20 ] && [ -z "$(jq -r '.rows[] | select(.prof_line | startswith("PROF fake p=") | not) | .id' <<<"$R")" ] && ok "F2 every prof_line is the PROF line" || bad "F2 prof: $(jq -c '[.rows[].prof_line]' <<<"$R")"
ARGVBAD=""
for i in $(seq 1 20); do
  printf -- '--x\0a b\0p%s\0' "$i" | cmp -s - "$T/runs/p$i.argv" || ARGVBAD="$ARGVBAD p$i"
done
[ "$NDONE" = 20 ] && [ -z "$ARGVBAD" ] && ok "F2 argv reaches the lane byte for byte" || bad "F2 argv differs for:$ARGVBAD"
[ "$(awk -F'\t' '$2 != "hub"' "$T/runs.tsv" | grep -c .)" = 20 ] && ok "F2 20 runs carry LANE_RUN_ID" || bad "F2 runs: $(cat "$T/runs.tsv")"
[ "$NDONE" = 20 ] && grep -q 'PROF fake p=' "$H/logs/demo-cron.log" && ok "F2 run output appended to logs/demo-cron.log" || bad "F2 cron log: $(tail -3 "$H/logs/demo-cron.log" 2>&1)"
S=$(curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/lane-runs/stats?lane=demo")
[ "$(jq '.lanes[0].done' <<<"$S")" = 20 ] && [ "$(jq '.lanes[0].queued' <<<"$S")" = 0 ] && ok "F2 stats done=20 queued=0" || bad "F2 stats: $S"

# ============================================================================
echo "F10: --once against an empty queue"
N0=$(jq '.rows | length' <<<"$(rows)")
timeout 5 "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/f10.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F10 exits 0 within 5 s" || bad "F10 rc=$rc $(cat "$T/f10.out")"
[ -n "$N0" ] && [ "$(jq '.rows | length' <<<"$(rows)")" = "$N0" ] && ok "F10 writes no row" || bad "F10 rows changed"
timeout 5 "$H/bin/lane-run-worker.sh" --once --machine 'bad name' > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "F10 a bad machine id exits 2" || bad "F10 bad machine rc=$rc"

# ============================================================================
echo "F4: a hub_only text keeps a fly lane on the hub"
CLEAN; FLEET 20; : > "$LOG1"
setting lane_placement.demo fly; setting lane_placement.demo.hub_only "reads builds/"
dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b"
WAITFOR '[ "$(nhub)" -ge 20 ]' && ok "F4 20 hub runs" || bad "F4 hub runs: $(nhub)"
[ "$(nposts "$LOG1")" = 0 ] && ok "F4 0 enqueues" || bad "F4 posts: $(nposts "$LOG1")"
case "$OUT" in *"placed: 0 fly, 20 hub (hub_only: reads builds/)"*) ok "F4 the line names the hub_only reason" ;; *) bad "F4 summary: $OUT" ;; esac
unsetting lane_placement.demo.hub_only

# ============================================================================
echo "F5: no lane row -> the seeded default hub"
CLEAN; : > "$LOG1"; unsetting lane_placement.demo
dispatch demo 0 "$H/bin/fake-lane.sh"
WAITFOR '[ "$(nhub)" -ge 20 ]' && ok "F5 20 hub runs" || bad "F5 hub runs: $(nhub)"
[ "$(nposts "$LOG1")" = 0 ] && ok "F5 0 enqueues" || bad "F5 posts: $(nposts "$LOG1")"
case "$OUT" in *"placed: 0 fly, 20 hub (lane_placement.default='hub' is not fly)"*) ok "F5 the line names the default" ;; *) bad "F5 summary: $OUT" ;; esac
[ "$(grep -c . "$H/logs/ALERTS.log")" = 0 ] && ok "F5 0 ALERTS lines" || bad "F5 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "F7: the adversarial placement table"
decide() { lp_decide "$1"; printf '%s|%s' "$LP_PLACE" "$LP_WHY"; }
setting lane_placement.blocked-resolver 'FLY '
D=$(decide blocked-resolver)
[ "${D%%|*}" = fly ] && ok "F7 'FLY ' is fly" || bad "F7 FLY: $D"
unsetting lane_placement.blocked-resolver; setting lane_placement.blocked-resolver-x fly
D=$(decide blocked-resolver)
[ "${D%%|*}" = hub ] && ok "F7 blocked-resolver-x=fly does not move blocked-resolver" || bad "F7 prefix: $D"
unsetting lane_placement.blocked-resolver-x
setting lane_placement.default fly
D=$(decide blocked-resolver)
[ "$D" = "fly|lane_placement.default=fly" ] && ok "F7 default fly with no lane row is fly" || bad "F7 default fly: $D"
setting lane_placement.blocked-resolver.hub_only "needs the hub's builds/"
D=$(decide blocked-resolver)
[ "$D" = "hub|hub_only: needs the hub's builds/" ] && ok "F7 default fly + hub_only is hub" || bad "F7 hub_only: $D"
unsetting lane_placement.blocked-resolver.hub_only; setting lane_placement.default hub
setting lane_placement.blocked-resolver ''
D=$(decide blocked-resolver)
[ "${D%%|*}" = hub ] && ok "F7 an empty value is hub" || bad "F7 empty: $D"
setting lane_placement.blocked-resolver box
D=$(decide blocked-resolver)
[ "$D" = "hub|lane_placement.blocked-resolver='box' is not fly" ] && ok "F7 box is hub, named" || bad "F7 box: $D"
unsetting lane_placement.blocked-resolver
D=$(decide 'Bad_Lane')
[ "$D" = "hub|lane name not a settings key" ] && ok "F7 a lane that is not a settings key is hub" || bad "F7 key: $D"
CLEAN; FLEET 2; setting lane_placement.demo box
dispatch demo 0 "$H/bin/fake-lane.sh"
case "$OUT" in *"placed: 0 fly, 2 hub (lane_placement.demo='box' is not fly)"*) ok "F7 box through pl_dispatch is hub" ;; *) bad "F7 dispatch: $OUT" ;; esac
WAITFOR '[ "$(nhub)" -ge 2 ]' || bad "F7 the 2 hub runs did not finish"

# ============================================================================
echo "F6: a second dispatch while the rows are live"
CLEAN; FLEET 20; setting lane_placement.demo fly
dispatch demo 0 "$H/bin/fake-lane.sh"
case "$OUT" in *"placed: 20 fly, 0 hub"*) ok "F6 first dispatch enqueues 20" ;; *) bad "F6 first: $OUT" ;; esac
dispatch demo 0 "$H/bin/fake-lane.sh"
case "$OUT" in *"placed: 0 fly, 0 hub (lane_placement.demo=fly), 20 already live"*) ok "F6 second dispatch counts 20 already live" ;; *) bad "F6 second: $OUT" ;; esac
wait_runs
[ "$(nhub)" = 0 ] && ok "F6 0 hub runs" || bad "F6 hub runs: $(nhub)"
[ "$(jq '[.rows[] | select(.status == "queued")] | length' <<<"$(rows)")" = 20 ] && ok "F6 still 20 live rows" || bad "F6 rows"

# ============================================================================
echo "F8: three failed enqueues fall back to the hub with ONE alert"
srv w2 NO_BATCH=1 FAIL_ENQUEUE_N=3 || true
export JOBS_URL="http://127.0.0.1:$PORT"
CLEAN; FLEET 20; setting lane_placement.demo fly
dispatch demo 0 "$H/bin/fake-lane.sh"
case "$OUT" in *"placed: 17 fly, 3 hub (lane_placement.demo=fly), 3 enqueue failed -> hub"*) ok "F8 17 fly, 3 hub, 3 failed" ;; *) bad "F8 summary: $OUT" ;; esac
WAITFOR '[ "$(nhub)" -ge 3 ]' && ok "F8 3 hub runs" || bad "F8 hub runs: $(nhub)"
wait_runs
[ "$(nhub)" = 3 ] && ok "F8 exactly 3 hub runs" || bad "F8 hub runs: $(nhub)"
[ "$(jq '.rows | length' <<<"$(rows)")" = 17 ] && ok "F8 17 rows" || bad "F8 rows"
# The jobs client writes its own once-a-day outage line on the 500s; the
# placement writes exactly one line of its own.
[ "$(nalerts_lp)" = 1 ] && grep 'lane-placement' "$H/logs/ALERTS.log" | grep -q 'demo: 3 of 20 fly enqueue(s) failed' \
  && ok "F8 exactly 1 lane-placement ALERTS line naming demo and the count" || bad "F8 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(grep -vc '\[jobs-client\]' "$H/logs/ALERTS.log")" = 1 ] && ok "F8 no other alert writer" || bad "F8 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "F11: a missing command is reported non-zero, never 0"
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/f11-drain.out" 2>&1
curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  -d '{"lane":"nope","project":"p1","args":["bin/nope.sh"]}' "$JOBS_URL/api/lane-runs" > /dev/null
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/f11.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F11 the loop exits 0" || bad "F11 rc=$rc $(cat "$T/f11.out")"
NR=$(jq -c '.rows[] | select(.lane == "nope")' <<<"$(rows)")
[ "$(jq -r .status <<<"$NR")" = done ] && [ "$(jq -r '.rc' <<<"$NR")" = 127 ] && ok "F11 reported rc 127" || bad "F11 row: $NR"

# ============================================================================
echo "F9: the worker is unreachable"
CLEAN; FLEET 20
JOBS_URL="http://127.0.0.1:1" dispatch demo 0 "$H/bin/fake-lane.sh"
WAITFOR '[ "$(nhub)" -ge 20 ]' && ok "F9 20 hub runs" || bad "F9 hub runs: $(nhub)"
case "$OUT" in *"placed: 0 fly, 20 hub (settings unreadable"*) ok "F9 the line says settings unreadable" ;; *) bad "F9 summary: $OUT" ;; esac
[ "$(nalerts_lp)" = 0 ] && ok "F9 0 lane-placement ALERTS lines" || bad "F9 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "F12: a command outside \$H/bin stays on the hub"
CLEAN; FLEET 2; : > "$T/w2.log"
cp "$H/bin/fake-lane.sh" "$T/outside-lane.sh"
dispatch demo 0 "$T/outside-lane.sh"
case "$OUT" in *"placed: 0 fly, 2 hub (lane_placement.demo=fly; cmd not under bin/)"*) ok "F12 hub, with the reason" ;; *) bad "F12 summary: $OUT" ;; esac
[ "$(nposts "$T/w2.log")" = 0 ] && ok "F12 0 enqueues" || bad "F12 posts"
WAITFOR '[ "$(nhub)" -ge 2 ]' && ok "F12 2 hub runs" || bad "F12 hub runs: $(nhub)"
[ "$(nalerts_lp)" = 0 ] && ok "F12 no alert" || bad "F12 alerts"

echo "project-lanes-fly: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
