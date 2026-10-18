#!/bin/bash
# tests/pipeline-health-placement.bh-7252-test.sh — BH-7252 C1: the
# lane_placement.pipeline-health row routes the pipeline-health project runs
# to lane-run, and the kill row (`hub`) sends them back to the hub.
#
# Driven through the REAL `bin/pipeline-health.sh --dispatch` (its own libs,
# the shared pl_dispatch, the REAL jobs client) over real curl against the
# REAL jobs worker on node:sqlite (tests/lib/lane-runs-worker.bh-6124.mjs),
# with a two-project fleet.conf. bin/project-lane-run.sh is a recorder, so a
# hub start is one line in $T/hub-starts.txt.
#
#   P1  row fly: 1 POST /api/lane-runs/batch, 2 queued pipeline-health rows
#       with args [bin/pipeline-health.sh, --project], 0 hub starts
#   P2  row hub (the kill row): 0 lane-runs calls, 2 hub starts
#   P3  row fly plus lane_placement.pipeline-health.hub_only: 0 batch calls,
#       2 hub starts, the reason in the dispatch line
#   P4  the rendered hub crontab runs `lane-snapshot-publish.sh --lane
#       pipeline-health` and `lane-move.sh`, each behind hub-lease.sh check
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-placement.bh-7252-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# The worker imports catalog/lanes.json and catalog/llm-sites.json (composed, git-ignored).
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SRV="$REPO/tests/lib/lane-runs-worker.bh-6124.mjs"

# ── P4 first: it needs no worker ────────────────────────────────────────────
if HARNESS_TEST_SANDBOX=1 "$REPO/bin/render-cron.sh" hub > "$T/hub.cron" 2> "$T/render.err"; then
  grep -E '^[^#].*/root/harness/bin/hub-lease\.sh check && /root/harness/bin/lane-snapshot-publish\.sh --lane pipeline-health( |$)' "$T/hub.cron" >/dev/null \
    && ok "P4 hub crontab: lane-snapshot-publish.sh --lane pipeline-health behind hub-lease" \
    || bad "P4 no gated --lane pipeline-health publisher line: $(grep -n 'lane-snapshot-publish.sh' "$T/hub.cron")"
  grep -E '^[^#].*/root/harness/bin/hub-lease\.sh check && /root/harness/bin/lane-move\.sh( |$)' "$T/hub.cron" >/dev/null \
    && ok "P4 hub crontab: lane-move.sh behind hub-lease" \
    || bad "P4 no gated lane-move.sh line: $(grep -n 'lane-move' "$T/hub.cron")"
  grep -E '^[^#].*/root/harness/bin/lane-snapshot-publish\.sh >>' "$T/hub.cron" >/dev/null \
    && ok "P4 the blocked-resolver publisher line stays" || bad "P4 the default publisher line is gone"
else bad "P4 render-cron.sh hub failed: $(cat "$T/render.err")"; fi

# ── the scratch hub ─────────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
for L in bin/pipeline-health.sh bin/fleet-conf.sh bin/lib/project-lanes.sh bin/lib/lane-placement.sh \
         bin/lib/lane-gate.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for f in beat.sh lane-alert.sh alert-line.sh queued-fly-relayed.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$2" >> "%s/hub-starts.txt"\nexit 0\n' "$T" > "$H/bin/project-lane-run.sh"
chmod +x "$H/bin/"*.sh
printf 'pa o/pa - - 2 box-pa 192.0.2.1\npb o/pb - - 2 box-pb 192.0.2.2\n' > "$H/fleet.conf"
: > "$H/env/global.env"; echo '{}' > "$H/state/health-alerted.json"
# No real credential reaches this run: gh records and answers nothing.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh.txt"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" GH_TOKEN="" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1
export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
export JOBS_TIMEOUT=30 BOX_NAME=fixture-box PH_DISPATCH_SPREAD_SECS=0 HARNESS_ENV_DIR="$H/env"
STEP_S="${BH7252_STEP_S:-180}"

SPID=""
: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
SPID=$!
trap '[ -n "$SPID" ] && kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 600); do [ -s "$T/w.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable (P4 ran: $PASS passed, $FAIL failed)"; [ "$FAIL" -eq 0 ]; exit; }
  echo "setup: worker did not start (rc $src): $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
setting()   { curl -fsS -m 15 -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null || bad "setup: PUT __setting $1"; }
unsetting() { curl -fsS -m 15 -X DELETE "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" '{key:$k}')" >/dev/null || bad "setup: DELETE __setting $1"; }
rows() { curl -sS -m 15 "$JOBS_URL/__lane_runs" | jq -c '[.rows[] | select(.lane == "pipeline-health")]'; }
nbatch() { grep -c '^POST /api/lane-runs/batch ' "$T/w.log" 2>/dev/null; }
nlr()    { grep -c '^POST /api/lane-runs' "$T/w.log" 2>/dev/null; }
nhub()   { grep -c . "$T/hub-starts.txt" 2>/dev/null; }
DISPATCH() {
  : > "$T/w.log"; : > "$T/hub-starts.txt"; : > "$H/logs/pipeline-health.log"
  timeout -k 5 "$STEP_S" bash "$H/bin/pipeline-health.sh" --dispatch >> "$T/run.log" 2>&1; DRC=$?
  [ "$DRC" = 124 ] && bad "dispatch did not finish in ${STEP_S}s"
  SUMMARY=$(grep 'pipeline-health dispatch:' "$H/logs/pipeline-health.log" | tail -1)
}

# ── P1 fly ──────────────────────────────────────────────────────────────────
setting lane_placement.pipeline-health fly
DISPATCH
[ "$DRC" = 0 ] && ok "P1 dispatch rc 0" || bad "P1 dispatch rc $DRC: $(tail -5 "$T/run.log")"
[ "$(nbatch)" = 1 ] && ok "P1 1 POST /api/lane-runs/batch" || bad "P1 batch calls $(nbatch): $(cat "$T/w.log")"
R=$(rows)
[ "$(jq 'length' <<<"$R")" = 2 ] && [ "$(jq -c '[.[].project] | sort' <<<"$R")" = '["pa","pb"]' ] \
  && ok "P1 2 lane_runs rows, pa and pb" || bad "P1 rows: $R"
jq -e 'all(.[]; .args[0] == "bin/pipeline-health.sh" and .args[1] == "--project" and .status == "queued")' <<<"$R" >/dev/null \
  && ok "P1 args [bin/pipeline-health.sh, --project], queued" || bad "P1 args: $R"
[ "$(nhub)" = 0 ] && ok "P1 0 hub starts" || bad "P1 hub starts: $(cat "$T/hub-starts.txt")"
grep -q 'placed: 2 fly, 0 hub' <<<"$SUMMARY" && ok "P1 dispatch line: 2 fly, 0 hub" || bad "P1 summary: $SUMMARY"

# ── P2 the kill row ─────────────────────────────────────────────────────────
setting lane_placement.pipeline-health hub
DISPATCH
[ "$DRC" = 0 ] && ok "P2 dispatch rc 0" || bad "P2 dispatch rc $DRC"
[ "$(nlr)" = 0 ] && ok "P2 0 lane-runs enqueues" || bad "P2 lane-runs calls: $(grep lane-runs "$T/w.log")"
[ "$(nhub)" = 2 ] && [ "$(sort "$T/hub-starts.txt" | paste -sd, -)" = pa,pb ] && ok "P2 2 hub starts (pa, pb)" \
  || bad "P2 hub starts: $(cat "$T/hub-starts.txt")"
grep -q 'placed: 0 fly, 2 hub' <<<"$SUMMARY" && ok "P2 dispatch line: 0 fly, 2 hub" || bad "P2 summary: $SUMMARY"

# ── P3 fly plus hub_only ────────────────────────────────────────────────────
setting lane_placement.pipeline-health fly
setting lane_placement.pipeline-health.hub_only "fixture: reads a hub file"
DISPATCH
[ "$(nbatch)" = 0 ] && ok "P3 0 batch calls" || bad "P3 batch calls: $(nbatch)"
[ "$(nhub)" = 2 ] && ok "P3 2 hub starts" || bad "P3 hub starts: $(cat "$T/hub-starts.txt")"
grep -q 'hub_only: fixture: reads a hub file' <<<"$SUMMARY" && ok "P3 the hub_only reason in the dispatch line" || bad "P3 summary: $SUMMARY"
unsetting lane_placement.pipeline-health.hub_only

echo "pipeline-health-placement: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
