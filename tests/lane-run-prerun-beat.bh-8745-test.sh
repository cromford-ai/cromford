#!/bin/bash
# tests/lane-run-prerun-beat.bh-8745-test.sh — BH-8745 fault 1 and 2: the row
# heartbeat of a lane run starts at claim, before the pre-run steps
# (lw_warm_ensure, lri_fetch), not after the spawn. Driven over real curl
# against the REAL jobs worker (tests/lib/lane-run-lease.bh-6125.mjs) and
# through the real bin/lane-run-worker.sh, bin/lib/lane-run-heartbeat.sh and
# bin/project-lane-run.sh.
#
# The pre-run delay is the warm ensure: LANE_RUN_WARM_CLONES=1 with a file://
# remote, and this suite holds locks/warm-<p>.lock for a few seconds.
#
#   B1  at least 1 heartbeat POST for the row before the lane starts; the row
#       ends done on wa, attempts 1
#   B2  the row is re-claimed by wb during wa's pre-run: wa starts nothing and
#       reports nothing; the row stays with wb
#   B2b the row is swept to died during wa's pre-run: wa starts nothing and
#       reports nothing
#   B3  a heartbeat outage (503) during the pre-run is not a lost lease: wa
#       runs and reports
#   B5  the row is re-claimed during the pre-run and the warm ensure then
#       fails (no remote): wa sends no rc 75 report, one `lease lost before
#       the run` line; control: the same failure with the row kept reports 75
#   B4  lane_run.prerun_beat_max_s=2 and a 5 s pre-run: the beats stop after
#       about 2 s and one `pre-run heartbeat stopped after` line is logged
#
# Run from anywhere: tests/lane-run-prerun-beat.bh-8745-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-run-lease.bh-6125.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, flock, setsid or git missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state/lane-run-worker" "$H/env" "$H/flags" "$T/repos" "$T/remotes/o"
for L in bin/project-lane-run.sh bin/lane-run-worker.sh bin/fleet-conf.sh bin/jobs-client.sh \
         bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_RUN_NOW=1791000000
export BOX_NAME=fixture-box LANE_RUN_WARM_CLONES=1 REPOS_ROOT="$T/repos" LANE_RUN_WARM_URL_BASE="file://$T/remotes"
: > "$H/fleet.conf"
for p in b1 b2 b2b b3 b4 b5 b5c; do
  printf '%s o/%s - - 2 box-%s 192.0.2.1\n' "$p" "$p" "$p" >> "$H/fleet.conf"
  case "$p" in b5*) ;; *) git init -q --bare "$T/remotes/o/$p.git" ;; esac
done
# The warm refresh before each claim is skipped: its stamp is "now".
echo "$LANE_RUN_NOW" > "$H/state/lane-run-worker/warm-refresh.at"

# The fake lane: arg <project>. Records how many heartbeats the row had
# answered 200 when it started, then exits 0.
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
p="\${@: -1}"
printf '%s\t%s\t%s\n' "\$p" "\${LANE_RUN_ID:-hub}" "\$(grep -c "^POST /api/lane-runs/\${LANE_RUN_ID:-x}/heartbeat " "$T/srv.log")" >> "$T/runs.tsv"
exit 0
EOF
chmod +x "$H/bin/fake-lane.sh"
: > "$T/runs.tsv"

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
BG=()
trap 'for p in "${BG[@]}" "$SPID"; do kill "$p" 2>/dev/null; done' EXIT

api() { curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d "$2" "$JOBS_URL$1"; }
hook() { curl -sS -X "$1" -d "$3" "$JOBS_URL$2" > /dev/null; }
setting() { hook PUT /__setting "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')"; }
expire() { hook POST /__expire "{\"id\":$1}"; }
rowf() { curl -sS "$JOBS_URL/__lane_runs" | jq -r --argjson id "$1" ".rows[] | select(.id == \$id) | $2"; }
rowj() { curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$1" '.rows[] | select(.id == $id)'; }
enqueue() { api /api/lane-runs "$(jq -nc --arg p "$1" '{lane:"demo",project:$p,args:["bin/fake-lane.sh",$p]}')" | jq -r .id; }
claim_as() { api /api/lane-runs/claim "{\"machine\":\"$1\"}" | jq -r '.id // empty'; }
WAITFOR() { local i; for i in $(seq 1 "${2:-50}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
nbeats() { grep -c "^POST /api/lane-runs/$1/heartbeat $2\$" "$T/srv.log"; }
nreports() { grep -c "^POST /api/lane-runs/$1/report " "$T/srv.log"; }
# hold <project> <seconds> — hold locks/warm-<p>.lock, so the worker's pre-run
# waits on it. Returns once the lock is held.
hold() { rm -f "$T/held-$1"; flock "$H/locks/warm-$1.lock" -c "touch '$T/held-$1'; sleep $2" & BG+=("$!")
  WAITFOR "[ -f '$T/held-$1' ]" 50 || bad "setup: could not hold the warm lock of $1"; }
# worker <machine> <out> — one --once worker in the background; pid in WPID.
worker() { "$H/bin/lane-run-worker.sh" --once --machine "$1" > "$2" 2>&1 & WPID=$!; BG+=("$WPID"); }
setting lane_run.heartbeat_s 1

# ============================================================================
echo "B1: the row beats during the pre-run, before the lane starts"
ID=$(enqueue b1)
hold b1 3
worker wa "$T/b1.out"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B1 the worker did not end within 20 s"
wait "$WPID"; rc=$?
[ "$rc" = 0 ] && ok "B1 wa's --once exits 0" || bad "B1 rc=$rc $(cat "$T/b1.out")"
N=$(awk -F'\t' -v id="$ID" '$1 == "b1" && $2 == id { print $3 }' "$T/runs.tsv")
[ -n "$N" ] && [ "$N" -ge 1 ] && ok "B1 $N heartbeat POST(s) for the row before the lane started" \
  || bad "B1 beats before the start: '${N:-no run}' (runs: $(cat "$T/runs.tsv"))"
[ "$(rowf "$ID" .status)" = done ] && [ "$(rowf "$ID" .claimed_by)" = wa ] && [ "$(rowf "$ID" .attempts)" = 1 ] \
  && ok "B1 the row ends done on wa, attempts 1" || bad "B1 row: $(rowj "$ID")"

# ============================================================================
echo "B2: the row is re-claimed during the pre-run; wa runs nothing, reports nothing"
ID=$(enqueue b2)
hold b2 4
worker wa "$T/b2.out"
WAITFOR "[ \"\$(rowf $ID .claimed_by)\" = wa ] && [ \$(nbeats $ID 200) -ge 1 ]" 30 \
  && ok "B2 wa claims and beats 200 during the pre-run" || bad "B2 wa did not beat in the pre-run: $(rowj "$ID")"
TOOK=""
for _ in 1 2 3 4 5; do expire "$ID"; [ "$(claim_as wb)" = "$ID" ] && { TOOK=1; break; }; done
[ -n "$TOOK" ] && ok "B2 wb claims the same id" || bad "B2 wb could not claim"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B2 wa did not end within 20 s"
wait "$WPID"; rc=$?
[ "$rc" = 0 ] && ok "B2 wa's --once exits 0" || bad "B2 rc=$rc"
! grep -q "^b2	" "$T/runs.tsv" && ok "B2 wa never started the lane" || bad "B2 the lane ran: $(cat "$T/runs.tsv")"
[ "$(nreports "$ID")" = 0 ] && ok "B2 0 report POSTs for the row" || bad "B2 a report was sent"
grep -q "run $ID demo/b2: lease lost during the pre-run (another machine claimed it); not run, not reported" "$H/logs/lane-run-worker.log" \
  && ok "B2 wa logs the lost pre-run" || bad "B2 log: $(tail -4 "$H/logs/lane-run-worker.log")"
[ "$(rowf "$ID" .status)" = claimed ] && [ "$(rowf "$ID" .claimed_by)" = wb ] && [ "$(rowf "$ID" .attempts)" = 2 ] \
  && ok "B2 the row stays claimed by wb, attempts 2" || bad "B2 row: $(rowj "$ID")"

# ============================================================================
echo "B2b: the row is swept to died during the pre-run; wa runs nothing"
setting lane_run.max_attempts 1
ID=$(enqueue b2b)
hold b2b 4
worker wa "$T/b2b.out"
WAITFOR "[ \"\$(rowf $ID .claimed_by)\" = wa ] && [ \$(nbeats $ID 200) -ge 1 ]" 30 \
  || bad "B2b wa did not beat in the pre-run: $(rowj "$ID")"
for _ in 1 2 3 4 5; do expire "$ID"; claim_as wb > /dev/null; [ "$(rowf "$ID" .status)" = died ] && break; done
[ "$(rowf "$ID" .status)" = died ] && ok "B2b the claim sweep turned the row died" || bad "B2b row: $(rowj "$ID")"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B2b wa did not end within 20 s"
wait "$WPID"
! grep -q "^b2b	" "$T/runs.tsv" && ok "B2b wa never started the lane" || bad "B2b the lane ran: $(cat "$T/runs.tsv")"
[ "$(nreports "$ID")" = 0 ] && ok "B2b 0 report POSTs for the row" || bad "B2b a report was sent"
[ "$(nbeats "$ID" 409)" -ge 1 ] && ok "B2b wa's beat got 409 lost" || bad "B2b no 409: $(grep "/$ID/" "$T/srv.log" | tail -3)"
setting lane_run.max_attempts 3

# ============================================================================
echo "B3: a heartbeat outage during the pre-run is not a lost lease"
ID=$(enqueue b3)
hook PUT /__heartbeat_fail '{"status":503,"body":"{\"error\":\"down\"}"}'
hold b3 3
worker wa "$T/b3.out"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B3 wa did not end within 20 s"
wait "$WPID"
hook PUT /__heartbeat_fail '{}'
[ "$(nbeats "$ID" 503)" -ge 1 ] && ok "B3 the pre-run beats answered 503" || bad "B3 no 503 beat"
grep -q "^b3	$ID	" "$T/runs.tsv" && ok "B3 the lane ran" || bad "B3 the lane did not run: $(tail -4 "$H/logs/lane-run-worker.log")"
[ "$(rowf "$ID" .status)" = done ] && [ "$(nreports "$ID")" = 1 ] && ok "B3 wa reported; the row is done" || bad "B3 row: $(rowj "$ID")"

# ============================================================================
echo "B5: a pre-run failure after the row was lost is not reported"
ID=$(enqueue b5)
hold b5 4
worker wa "$T/b5.out"
WAITFOR "[ \"\$(rowf $ID .claimed_by)\" = wa ] && [ \$(nbeats $ID 200) -ge 1 ]" 30 || bad "B5 wa did not beat in the pre-run"
for _ in 1 2 3 4 5; do expire "$ID"; [ "$(claim_as wb)" = "$ID" ] && break; done
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B5 wa did not end within 20 s"
wait "$WPID"
[ "$(nreports "$ID")" = 0 ] && ok "B5 0 report POSTs (no rc 75 for a lost row)" || bad "B5 a report was sent"
grep -q "run $ID: lease lost before the run; not reported" "$H/logs/lane-run-worker.log" && ok "B5 one 'lease lost before the run' line" \
  || bad "B5 log: $(tail -4 "$H/logs/lane-run-worker.log")"
ID=$(enqueue b5c)
worker wa "$T/b5c.out"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B5c wa did not end within 20 s"
wait "$WPID"
[ "$(rowf "$ID" .rc)" = 75 ] && [ "$(nreports "$ID")" = 1 ] && ok "B5c control: the kept row is reported rc 75" || bad "B5c row: $(rowj "$ID")"

# ============================================================================
echo "B4: lane_run.prerun_beat_max_s bounds the pre-run beat"
setting lane_run.prerun_beat_max_s 2
ID=$(enqueue b4)
hold b4 5
worker wa "$T/b4.out"
WAITFOR "! kill -0 $WPID 2>/dev/null" 200 || bad "B4 wa did not end within 20 s"
wait "$WPID"
N=$(awk -F'\t' -v id="$ID" '$1 == "b4" && $2 == id { print $3 }' "$T/runs.tsv")
[ -n "$N" ] && [ "$N" -ge 1 ] && [ "$N" -le 3 ] && ok "B4 $N beat(s) in a 5 s pre-run (1..3)" || bad "B4 beats before the start: '${N:-no run}'"
[ "$(grep -c "run $ID: pre-run heartbeat stopped after 2s" "$H/logs/lane-run-worker.log")" = 1 ] \
  && ok "B4 one 'pre-run heartbeat stopped after 2s' line" || bad "B4 log: $(grep "run $ID" "$H/logs/lane-run-worker.log")"
[ "$(rowf "$ID" .status)" = done ] && ok "B4 the run still ends done" || bad "B4 row: $(rowj "$ID")"
setting lane_run.prerun_beat_max_s 600

echo "lane-run-prerun-beat: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
