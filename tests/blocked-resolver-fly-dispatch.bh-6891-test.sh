#!/bin/bash
# tests/blocked-resolver-fly-dispatch.bh-6891-test.sh — BH-6891: the
# blocked-resolver cron dispatch, placed on Fly, makes ONE batch enqueue and
# starts no hub process; placed on the hub, it dispatches as before.
#
# Driven through the REAL `bin/blocked-resolver.sh --dispatch` (its hold gate,
# its own libraries, the shared pl_dispatch) over real curl against the REAL
# jobs worker on node:sqlite (tests/lib/lane-runs-worker.bh-6124.mjs), with a
# 13-project fleet.conf (the fleet size on 2026-10-15). bin/project-lane-run.sh
# is a recorder, so a hub start is one line in $T/hub-starts.txt.
#
#   D1  lane_placement.blocked-resolver=fly: 1 POST /api/lane-runs/batch,
#       0 single POST /api/lane-runs, 0 hub starts, 13 queued rows,
#       `placed: 13 fly, 0 hub`, no lane-placement alert
#   D4  a second dispatch with the 13 rows live: 1 more batch call, still 13
#       rows, 0 hub starts, `13 already live`
#   D2  no blocked-resolver row, lane_placement.default=hub: 0 lane-runs
#       calls, 13 hub starts (p01..p13), `placed: 0 fly, 13 hub`
#   D5  the fly row plus a hub_only row: 0 batch calls, 13 hub starts, the
#       hub_only reason in the summary
#   D3  the fly row, p07 held (flags/lane-off-blocked-resolver-p07), a fresh
#       worker: 1 batch call, 12 rows, none for p07, 0 hub starts, `1 held`
#
# Run from anywhere: tests/blocked-resolver-fly-dispatch.bh-6891-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# BH-6619: the worker imports catalog/lanes.json and catalog/llm-sites.json,
# both composed and git-ignored. The worker this suite starts needs them on disk.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SRV="$REPO/tests/lib/lane-runs-worker.bh-6124.mjs"

# ---------------------------------------------------------------------------
# The scratch hub: the lane, its modules, the dispatcher's libs and the REAL
# jobs client, so _jobs_req, setting_get and _setting_key_ok are the shipped ones.
# ---------------------------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
cp "$REPO/bin/blocked-resolver.sh" "$REPO/bin/merge-conductor.sh" "$REPO/bin/fleet-conf.sh" "$REPO/bin/project-of.sh" "$REPO/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$REPO/tests/lib/br-modules.sh" || exit 1
br_modules_install "$REPO" "$H" || exit 1
for L in bin/lib/project-lanes.sh bin/lib/lane-placement.sh bin/lib/lane-gate.sh bin/lib/hold.sh \
         bin/lib/gh-app-auth.sh bin/jobs-client.sh bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh \
         bin/lib/rebuild-ledger.sh bin/lib/gh-rest.sh $(cd "$REPO" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"
done
# The hub start recorder: pl_dispatch runs `project-lane-run.sh <lane> <project> <off> <cmd>`.
printf '#!/bin/bash\nprintf "%%s\\n" "$2" >> "%s/hub-starts.txt"\nexit 0\n' "$T" > "$H/bin/project-lane-run.sh"
chmod +x "$H/bin/"*.sh
PROJECTS=$(for I in $(seq 1 13); do printf 'p%02d\n' "$I"; done)
while read -r p; do printf '%s o/%s - - 2 box-%s 192.0.2.%s\n' "$p" "$p" "$p" "${p#p}"; done <<<"$PROJECTS" > "$H/fleet.conf"
# shellcheck source=tests/lib/model-route-stub.sh
. "$REPO/tests/lib/model-route-stub.sh" || exit 1
# shellcheck disable=SC2086
mrs_fixture "$H" $PROJECTS
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"

# NO REAL CREDENTIAL REACHES THIS RUN: gh records and answers empty.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh.txt"\necho ""\nexit 0\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" GH_TOKEN="" HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
export BOX_NAME=fixture-box BR_DISPATCH_SPREAD_SECS=0
# A loaded box answers slower than the client's 8 s default. With
# JOBS_RETRIES=0 one slow read is "settings unreadable" and the lane falls to
# the hub (the D5 failure seen on a busy hub on 2026-10-16). 30 s absorbs load;
# retries stay 0 so a request is never counted twice.
export JOBS_TIMEOUT=30
# Every step is bounded: one hung step must fail the suite, never stall a shard.
STEP_S="${BH6891_STEP_S:-120}"

PIDS=()
# srv <name> -> PORT, or rc 3 (no node:sqlite)
srv() {
  local n="$1"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 600); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  [ -n "$PORT" ] && return 0
  # A worker that is still alive after 30 s with no port is hung: kill it and
  # fail. Never `wait` on a live pid (that blocked D3 with no end).
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; return 1; fi
  wait "$pid"; return $?
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
# A fixture write that fails is a setup failure, named, not a later odd summary.
setting() { curl -fsS -m 15 -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null \
  || bad "setup: PUT __setting $1=$2 failed"; }
unsetting() { curl -fsS -m 15 -X DELETE "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" '{key:$k}')" >/dev/null \
  || bad "setup: DELETE __setting $1 failed"; }
rows() { curl -sS -m 15 "$JOBS_URL/__lane_runs" | jq -c '[.rows[] | select(.lane == "blocked-resolver")]'; }
# B = batch enqueues, S = single enqueues, in this case's request log.
nbatch()  { grep -c '^POST /api/lane-runs/batch ' "$REQ" 2>/dev/null; }
nsingle() { grep -c '^POST /api/lane-runs ' "$REQ" 2>/dev/null; }
nhub()    { grep -c . "$T/hub-starts.txt" 2>/dev/null; }
WAITFOR() { local i; for i in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# DISPATCH — one cron tick of the real lane; SUMMARY is its dispatch line.
DISPATCH() {
  : > "$REQ"; : > "$T/hub-starts.txt"; : > "$H/logs/blocked-resolver.log"
  : > "$H/logs/jobs-client.log"
  timeout -k 5 "$STEP_S" bash "$H/bin/blocked-resolver.sh" --dispatch >> "$T/run.log" 2>&1; DRC=$?
  [ "$DRC" = 124 ] && bad "dispatch did not finish in ${STEP_S}s"
  SUMMARY=$(grep 'blocked-resolver dispatch:' "$H/logs/blocked-resolver.log" | tail -1)
  # The client's own log names a transport or HTTP failure behind a summary
  # such as "settings unreadable"; print it so a red run shows its cause.
  [ -s "$H/logs/jobs-client.log" ] && sed 's/^/    jobs-client: /' "$H/logs/jobs-client.log" | tail -5
  return 0
}

srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start (rc $src): $(cat "$T/w1.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"
REQ="$T/w1.log"

# ============================================================================
echo "D1: placement fly, 13 projects -> one batch enqueue, no hub process"
setting lane_placement.blocked-resolver fly
DISPATCH
[ "$DRC" = 0 ] && ok "D1 dispatch rc 0" || bad "D1 dispatch rc $DRC: $(tail -5 "$T/run.log")"
[ "$(nbatch)" = 1 ] && [ "$(nsingle)" = 0 ] && ok "D1 1 POST /api/lane-runs/batch, 0 single enqueues" \
  || bad "D1 B=$(nbatch) S=$(nsingle) (want B=1 S=0)"
sleep 0.3
[ "$(nhub)" = 0 ] && ok "D1 0 hub starts" || bad "D1 hub starts: $(tr '\n' ' ' < "$T/hub-starts.txt")"
R=$(rows)
[ "$(jq '[.[] | select(.status == "queued")] | length' <<<"$R")" = 13 ] \
  && [ "$(jq -r '[.[].project] | sort | .[]' <<<"$R")" = "$PROJECTS" ] \
  && [ "$(jq '[.[] | select(.args[0] != "bin/blocked-resolver.sh")] | length' <<<"$R")" = 0 ] \
  && ok "D1 13 queued rows, one per project p01..p13, each running bin/blocked-resolver.sh" \
  || bad "D1 rows: $(jq -c '[.[] | {project,status,args}]' <<<"$R")"
case "$SUMMARY" in *"placed: 13 fly, 0 hub (lane_placement.blocked-resolver=fly)"*) ok "D1 summary: placed: 13 fly, 0 hub" ;;
  *) bad "D1 summary: $SUMMARY" ;; esac
grep -q 'lane-placement:blocked-resolver' "$H/logs/ALERTS.log" && bad "D1 a lane-placement alert: $(cat "$H/logs/ALERTS.log")" \
  || ok "D1 no lane-placement alert"

# ============================================================================
echo "D4: a second tick with the 13 rows live -> one more batch call, no new row"
DISPATCH
[ "$(nbatch)" = 1 ] && [ "$(nsingle)" = 0 ] && ok "D4 1 more batch call, 0 single enqueues" \
  || bad "D4 B=$(nbatch) S=$(nsingle) (want B=1 S=0)"
sleep 0.3
[ "$(nhub)" = 0 ] && ok "D4 0 hub starts" || bad "D4 hub starts: $(tr '\n' ' ' < "$T/hub-starts.txt")"
[ "$(rows | jq length)" = 13 ] && ok "D4 still 13 rows" || bad "D4 rows: $(rows | jq length)"
case "$SUMMARY" in *"13 already live"*) ok "D4 summary: 13 already live" ;; *) bad "D4 summary: $SUMMARY" ;; esac

# ============================================================================
echo "D2: placement hub (no lane row, default hub) -> 13 hub starts, as today"
unsetting lane_placement.blocked-resolver
setting lane_placement.default hub
DISPATCH
[ "$(nbatch)" = 0 ] && [ "$(nsingle)" = 0 ] && ok "D2 0 lane-runs calls" || bad "D2 B=$(nbatch) S=$(nsingle) (want 0 0)"
WAITFOR '[ "$(nhub)" -ge 13 ]'
[ "$(LC_ALL=C sort "$T/hub-starts.txt")" = "$PROJECTS" ] && ok "D2 13 hub starts, p01..p13" \
  || bad "D2 hub starts: $(tr '\n' ' ' < "$T/hub-starts.txt")"
case "$SUMMARY" in *"placed: 0 fly, 13 hub (lane_placement.default='hub' is not fly)"*) ok "D2 summary: placed: 0 fly, 13 hub" ;;
  *) bad "D2 summary: $SUMMARY" ;; esac

# ============================================================================
echo "D5: the fly row plus a hub_only row -> the hub, no batch call"
setting lane_placement.blocked-resolver fly
setting lane_placement.blocked-resolver.hub_only fixture
DISPATCH
[ "$(nbatch)" = 0 ] && [ "$(nsingle)" = 0 ] && ok "D5 0 lane-runs calls" || bad "D5 B=$(nbatch) S=$(nsingle) (want 0 0)"
WAITFOR '[ "$(nhub)" -ge 13 ]'
[ "$(LC_ALL=C sort "$T/hub-starts.txt")" = "$PROJECTS" ] && ok "D5 13 hub starts" \
  || bad "D5 hub starts: $(tr '\n' ' ' < "$T/hub-starts.txt")"
case "$SUMMARY" in *"hub_only: fixture"*) ok "D5 summary names the hub_only reason" ;; *) bad "D5 summary: $SUMMARY" ;; esac
stop_all

# ============================================================================
echo "D3: the fly row, p07 held, a fresh worker -> one batch call, 12 rows"
srv w2; src=$?; REQ="$T/w2.log"
[ -n "$PORT" ] || { echo "setup: worker 2 did not start (rc $src): $(cat "$T/w2.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"
setting lane_placement.blocked-resolver fly
touch "$H/flags/lane-off-blocked-resolver-p07"
DISPATCH
[ "$(nbatch)" = 1 ] && [ "$(nsingle)" = 0 ] && ok "D3 1 batch call, 0 single enqueues" \
  || bad "D3 B=$(nbatch) S=$(nsingle) (want B=1 S=0)"
sleep 0.3
[ "$(nhub)" = 0 ] && ok "D3 0 hub starts" || bad "D3 hub starts: $(tr '\n' ' ' < "$T/hub-starts.txt")"
R=$(rows)
[ "$(jq '[.[] | select(.status == "queued")] | length' <<<"$R")" = 12 ] \
  && [ "$(jq '[.[] | select(.project == "p07")] | length' <<<"$R")" = 0 ] \
  && ok "D3 12 queued rows, none for p07" || bad "D3 rows: $(jq -c '[.[] | {project,status}]' <<<"$R")"
case "$SUMMARY" in *", 1 held:"*) ok "D3 summary: 1 held" ;; *) bad "D3 summary: $SUMMARY" ;; esac

echo "blocked-resolver-fly-dispatch: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
