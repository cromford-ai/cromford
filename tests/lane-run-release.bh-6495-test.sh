#!/bin/bash
# tests/lane-run-release.bh-6495-test.sh — BH-6495 (BH-6047.5) AC3: SIGTERM to
# bin/lane-run-worker.sh during a run hands the claimed row back to the queue
# (POST /api/lane-runs/:id/release), and another machine resumes it.
#
# Driven over real curl against the REAL jobs worker
# (tests/lib/lane-runs-worker.bh-6124.mjs), through the real
# bin/lane-run-worker.sh and bin/project-lane-run.sh.
#
#   R1  TERM during a run: the run's process group gets TERM, the worker exits
#       0, the row is queued again with claimed_by NULL and attempts 1, and no
#       report was posted
#   R2  a second --once machine claims it (attempts 2) and reports done rc 0
#   R3  TERM with no run in flight (an idle poll loop) exits 0 at once and
#       writes nothing
#   R4  a run that ignores TERM is killed after lane_run.term_grace_s, and
#       the row is still released
#   R5  the release itself fails (the worker is gone): the worker still exits
#       0 and logs one line; the lease re-runs the row
#
# Run from anywhere: tests/lane-run-release.bh-6495-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box

# The lane: marks its start and its attempt, then blocks while $T/block
# exists. TERM is recorded; with $T/ignore it is ignored (R4).
cat > "$H/bin/slow-lane.sh" <<EOF
#!/bin/bash
trap 'echo "term \$LANE_RUN_ID" >> "$T/term.txt"; [ -e "$T/ignore" ] || exit 143' TERM
echo "start \$LANE_RUN_ID" >> "$T/start.txt"
i=0; while [ -e "$T/block" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
echo "PROF slow p=\${@: -1}"
exit 0
EOF
chmod +x "$H/bin/slow-lane.sh"

PIDS=()
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid"); SPID=$pid
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT"; SLOG="$T/$n.log"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
rows() { curl -sS "$JOBS_URL/__lane_runs"; }
enq() { curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
          -d '{"lane":"slow","project":"p1","args":["bin/slow-lane.sh"]}' "$JOBS_URL/api/lane-runs" | jq -r .id; }
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
WLOG="$H/logs/lane-run-worker.log"

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }

# ============================================================================
echo "R1: TERM during a run releases the row"
: > "$T/start.txt"; : > "$T/term.txt"; : > "$T/block"
ID=$(enq)
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/r1.out" 2>&1 & W=$!
WAITFOR '[ -s "$T/start.txt" ]' || bad "R1 setup: the run never started: $(cat "$T/r1.out" "$WLOG")"
kill -TERM "$W"; wait "$W"; rc=$?
[ "$rc" = 0 ] && ok "R1 the worker exits 0" || bad "R1 rc=$rc $(cat "$T/r1.out")"
grep -q "^term $ID$" "$T/term.txt" && ok "R1 the run got TERM" || bad "R1 the run got no TERM: $(cat "$T/term.txt")"
R=$(rows | jq -c --argjson id "$ID" '.rows[] | select(.id == $id)')
[ "$(jq -r .status <<<"$R")" = queued ] && [ "$(jq -r .claimed_by <<<"$R")" = null ] && [ "$(jq -r .attempts <<<"$R")" = 1 ] \
  && ok "R1 the row is queued, claimed_by NULL, attempts 1" || bad "R1 row: $R"
[ "$(jq -r .rc <<<"$R")" = null ] && ! grep -q "/report " "$SLOG" && ok "R1 no report was posted" || bad "R1 report: $(grep report "$SLOG")"
grep -q "POST /api/lane-runs/$ID/release 200" "$SLOG" && ok "R1 one release POST answered 200" || bad "R1 server log: $(cat "$SLOG")"
grep -q "run $ID slow/p1: TERM — released to the queue" "$WLOG" && ok "R1 the worker log names the release" || bad "R1 log: $(tail -3 "$WLOG")"

# ============================================================================
echo "R2: another machine resumes it"
rm -f "$T/block"
"$H/bin/lane-run-worker.sh" --once --machine m2 > "$T/r2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "R2 the second worker exits 0" || bad "R2 rc=$rc $(cat "$T/r2.out")"
R=$(rows | jq -c --argjson id "$ID" '.rows[] | select(.id == $id)')
[ "$(jq -r .status <<<"$R")" = done ] && [ "$(jq -r .rc <<<"$R")" = 0 ] && [ "$(jq -r .attempts <<<"$R")" = 2 ] \
  && [ "$(jq -r .claimed_by <<<"$R")" = m2 ] && [ "$(jq -r .prof_line <<<"$R")" = "PROF slow p=p1" ] \
  && ok "R2 done rc 0 by m2, attempts 2, the PROF line stored" || bad "R2 row: $R"

# ============================================================================
echo "R3: TERM with no run in flight"
setting lane_run.poll_s 30
N0=$(rows | jq '.rows | length'); L0=$(grep -c . "$SLOG")
"$H/bin/lane-run-worker.sh" --machine m3 > "$T/r3.out" 2>&1 & W=$!
WAITFOR '[ "$(grep -c "POST /api/lane-runs/claim 204" "$SLOG")" -ge 1 ]' || bad "R3 setup: no empty claim seen"
sleep 0.5   # inside the 30 s poll sleep now
T0=$(date +%s); kill -TERM "$W"; wait "$W"; rc=$?; T1=$(date +%s)
[ "$rc" = 0 ] && ok "R3 the idle loop exits 0" || bad "R3 rc=$rc"
[ $((T1 - T0)) -le 3 ] && ok "R3 within 3 s, not after its 30 s poll sleep" || bad "R3 took $((T1 - T0)) s"
[ "$(rows | jq '.rows | length')" = "$N0" ] && ok "R3 no row written" || bad "R3 rows changed"
[ -z "$(tail -n +"$((L0 + 1))" "$SLOG" | grep -v '^POST /api/lane-runs/claim 204$' | grep -v '^GET /api/settings' | grep -v ' /__')" ] \
  && ok "R3 no request but the empty claim and the poll setting" || bad "R3 server log: $(tail -n +"$((L0 + 1))" "$SLOG")"
setting lane_run.poll_s 1

# ============================================================================
echo "R4: a run that ignores TERM is killed after the grace"
setting lane_run.term_grace_s 1
: > "$T/start.txt"; : > "$T/term.txt"; : > "$T/block"; : > "$T/ignore"
ID=$(enq)
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/r4.out" 2>&1 & W=$!
WAITFOR '[ -s "$T/start.txt" ]' || bad "R4 setup: the run never started"
T0=$(date +%s); kill -TERM "$W"; wait "$W"; rc=$?; T1=$(date +%s)
[ "$rc" = 0 ] && ok "R4 the worker exits 0" || bad "R4 rc=$rc"
[ $((T1 - T0)) -le 4 ] && ok "R4 within the 1 s grace plus slack, not the run's 30 s" || bad "R4 took $((T1 - T0)) s"
grep -q "^term $ID$" "$T/term.txt" && ok "R4 the run saw TERM first" || bad "R4 term: $(cat "$T/term.txt")"
[ "$(rows | jq -r --argjson id "$ID" '.rows[] | select(.id == $id) | .status')" = queued ] && ok "R4 the row is released" \
  || bad "R4 row: $(rows | jq -c --argjson id "$ID" '.rows[] | select(.id == $id)')"
WAITFOR '! pgrep -f "$H/bin/slow-lane.sh" >/dev/null' 30 && ok "R4 no run process is left" || bad "R4 a slow-lane process survived"
rm -f "$T/ignore" "$T/block"
"$H/bin/lane-run-worker.sh" --once --machine m2 >/dev/null 2>&1   # drain it

# ============================================================================
echo "R5: the release fails"
: > "$T/start.txt"; : > "$T/block"
ID=$(enq)
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/r5.out" 2>&1 & W=$!
WAITFOR '[ -s "$T/start.txt" ]' || bad "R5 setup: the run never started"
kill "$SPID"; wait "$SPID" 2>/dev/null
kill -TERM "$W"; wait "$W"; rc=$?
[ "$rc" = 0 ] && ok "R5 the worker exits 0" || bad "R5 rc=$rc"
grep -q "run $ID slow/p1: TERM — release failed (http " "$WLOG" && ok "R5 one release-failed line" || bad "R5 log: $(tail -3 "$WLOG")"
rm -f "$T/block"

echo "lane-run-release: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
