#!/bin/bash
# tests/d1-retention.bh-6750-test.sh — BH-6750 (slice 2 of BH-6727): the
# hourly D1 retention lane, bin/d1-retention.sh, driven over real curl against
# the REAL jobs worker (tests/lib/retention-worker.bh-6750.mjs; the route is
# worker/jobs/src/routes/retention.js, its own node suite is
# worker/jobs/test/retention.bh-6750.test.js).
#
#   D1  dry run (the seed): one log line per rule with counted=, a run line
#       with dry=1, and no row removed
#   D2  retention.dry_run=0: the old wakes go, the log says removed=, the run
#       line sums them, retention_runs has one row per rule
#   D3  no JOBS_URL: exit 0, `not-configured`, no ALERTS line
#   D4  the worker answers 500: exit 0, ONE unreachable alert over 2 runs
#   D5  flags/lane-off-d1-retention: no request at all
#   D6  the script never names cost_rows or ledgers, and names no model
#
# Run from anywhere: tests/d1-retention.bh-6750-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/retention-worker.bh-6750.mjs"
SCRIPT_REL=bin/d1-retention.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$SCRIPT_REL" bin/jobs-client.sh bin/lane-alert.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
for f in "$DIR/bin/d1-retention.sh" "$DIR/worker/jobs/src/routes/retention.js" "$SRV" \
         "$DIR/catalog/lanes.d/d1-retention.json" "$DIR/cron/lanes/731-d1-retention.cron"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
export HARNESS="$H"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 D1_RETENTION_NOW=1791000000
export BOX_NAME=hub

PIDS=()
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
sql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
get() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
run() { "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?; }
lastlog() { tail -1 "$H/logs/d1-retention.log" 2>/dev/null; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/d1-retention.log"; scratch_rm "$H/state/alerts"; }

srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"
# 5 wakes older than 30 days, 1 recent one, all unacked.
sql "INSERT INTO wakes (repo, kind, key, event, minute, at) SELECT 'o/r','pr', 'k'||value, 'e', '2020-01-01T00:00', '2020-01-01T00:00:00Z' FROM json_each('[1,2,3,4,5]');
     INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES ('o/r','pr','new','e', strftime('%Y-%m-%dT%H:%M','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

# --- D1: dry run -------------------------------------------------------------
RESET; run
[ "$RC" = 0 ] && ok "D1 rc 0" || bad "D1 rc $RC: $(cat "$T/run.out")"
grep -q ' wakes.age dry=1 counted=5 removed=0 backlog=1$' "$H/logs/d1-retention.log" && ok "D1 wakes.age counted 5, removed 0" \
  || bad "D1 log: $(cat "$H/logs/d1-retention.log")"
grep -qE ' run ret-[^ ]+ dry=1 rules=12 removed=0 errors=0$' <<<"$(lastlog)" && ok "D1 run line" || bad "D1 run line: $(lastlog)"
[ "$(get "SELECT COUNT(*) n FROM wakes" | jq -r '.[0].n')" = 6 ] && ok "D1 no wake removed" || bad "D1 wakes removed on a dry run"

# --- D2: real run ------------------------------------------------------------
sql "UPDATE settings SET value='0' WHERE key='retention.dry_run'"
RESET; run
grep -q ' wakes.age dry=0 counted=5 removed=5 backlog=0$' "$H/logs/d1-retention.log" && ok "D2 wakes.age removed 5" \
  || bad "D2 log: $(cat "$H/logs/d1-retention.log")"
grep -qE ' run ret-[^ ]+ dry=0 rules=12 removed=5 errors=0$' <<<"$(lastlog)" && ok "D2 run line sums the rules" || bad "D2 run line: $(lastlog)"
[ "$(get "SELECT COUNT(*) n FROM wakes" | jq -r '.[0].n')" = 1 ] && ok "D2 the recent wake stays" || bad "D2 wakes left: $(get 'SELECT key FROM wakes')"
[ "$(get "SELECT COUNT(*) n FROM retention_runs WHERE dry_run=0" | jq -r '.[0].n')" = 12 ] && ok "D2 one audit row per rule" \
  || bad "D2 audit rows: $(get 'SELECT rule, dry_run FROM retention_runs')"

# --- D3: not configured ------------------------------------------------------
RESET
( unset JOBS_URL; JOBS_URL="" "$H/$SCRIPT_REL" ) > "$T/run.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'not-configured (no-url)' "$H/logs/d1-retention.log" && ok "D3 not-configured" || bad "D3: rc=$RC $(cat "$H/logs/d1-retention.log")"
[ ! -s "$H/logs/ALERTS.log" ] && ok "D3 no alert" || bad "D3 alerted: $(cat "$H/logs/ALERTS.log")"

# --- D4: the worker answers 500 ----------------------------------------------
srv w2 FAIL_ALL=1
RESET
JOBS_URL="http://127.0.0.1:$PORT" "$H/$SCRIPT_REL" >/dev/null 2>&1
JOBS_URL="http://127.0.0.1:$PORT" "$H/$SCRIPT_REL" >/dev/null 2>&1
[ "$(grep -c 'd1-retention' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok "D4 one unreachable alert over 2 runs" \
  || bad "D4 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'worker-failed' "$H/logs/d1-retention.log" && ok "D4 worker-failed line" || bad "D4 log: $(cat "$H/logs/d1-retention.log")"

# --- D5: the lane is off -----------------------------------------------------
: > "$T/w1.log"; : > "$H/flags/lane-off-d1-retention"; RESET; run
grep -q 'retention/run' "$T/w1.log" && bad "D5 the lane ran with its off flag" || ok "D5 no request with the off flag"
rm -f "$H/flags/lane-off-d1-retention"

# --- D6: the script never names money tables or a model ----------------------
CODE=$(grep -vE '^[[:space:]]*#' "$DIR/$SCRIPT_REL")
grep -qE 'cost_rows|ledgers' <<<"$CODE" && bad "D6 the script names cost_rows or ledgers" || ok "D6 no money table"
grep -qiE 'claude|opus|sonnet|haiku|agent-call' <<<"$CODE" && bad "D6 the script names a model" || ok "D6 no model"

echo "d1-retention.bh-6750: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
