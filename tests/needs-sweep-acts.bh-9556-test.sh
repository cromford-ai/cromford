#!/bin/bash
# tests/needs-sweep-acts.bh-9556-test.sh — BH-9556 (slice C0): the NEEDS sweep
# acts by default, and a settings outage is an error, not a dry run.
# bin/needs-sweep.sh is driven over real curl against
# tests/lib/needs-sweep-world.bh-9117.mjs (the REAL Pages endpoint and the REAL
# jobs worker on the composed schema). A jobs outage is a closed port or a
# local node server that answers 500. GitHub is a `gh` stub. No call leaves
# the box. Each case has its own world server, tmp dir and port.
#
#   A1  no console.needs.sweep_dry_run row -> summary mode=apply, an apply POST
#   A2  row 1 (an operator kill flag) -> mode=dry, no apply:true POST
#   A3  jobs URL at a closed port -> rc 4, ONE needs-sweep-settings alert,
#       0 candidates GETs, no ledger row
#   A4  jobs answers 500 -> rc 4, ONE alert, 0 candidates GETs
#   A5  JOBS_URL="" -> rc 0, not-configured, 0 alerts, 0 candidates GETs
#   A6  row `junk` -> apply (fallback 0); row ` 0` and `10` -> apply
#   A7  --dry-run with row 0 -> dry
#   A8  the untouched seed row (1, actor seed) -> the worker moves it, apply
#
# Run from anywhere: tests/needs-sweep-acts.bh-9556-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/needs-sweep-world.bh-9117.mjs"
SCRIPT_REL=bin/needs-sweep.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

NOW=$(date -u -d 2026-11-24T22:00:00Z +%s)
iso_ago() { date -u -d "@$((NOW - $1 * 86400))" +%FT%TZ; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/fakebin"
for L in "$SCRIPT_REL" bin/builds-merged-sweep.sh bin/jobs-client.sh bin/alert-line.sh bin/fleet-conf.sh bin/lib/tracker.sh \
         bin/lib/tracker/github-issues.sh bin/lib/tracker/board.sh bin/lib/gh-rest.sh bin/lib/console-pages.sh bin/lib/lane-gate.sh bin/lib/mc/settle.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf 'demo-board o/board https://board.example /api/board 2 hub\n' > "$H/fleet.conf"
# The gh stub: every read is a 404 and is logged; the seed rows need no read.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.txt"\nprintf "HTTP/2.0 404\\r\\n\\r\\n{}"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=fixture-gh-token
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 BOX_NAME=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0
unset CONSOLE_URL MC_CLOSED_SETTLE

# Two rows: one aged plan_blocked row (stale aged) and one young one (kept).
SEED="$T/seed.sql"
{ echo "INSERT INTO builds (id,bkey,project,ticket_key,stage,pr_url,merged,updated_at) VALUES"
  echo " (1,'k1','demo-board','TK-1','plan_blocked','',0,'$(iso_ago 30)'),"
  echo " (2,'k2','demo-board','TK-2','plan_blocked','',0,'$(iso_ago 1)');"; } > "$SEED"

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
srv() { # srv <name> — a fresh world; sets PORT, W, JOBS_URL, CONSOLE_PAGES_URL
  local n="$1"
  : > "$T/$n.log"; : > "$T/$n.port"; : > "$T/$n.bodies"
  node "$SRV" "$T/$n.log" "$SEED" "$T/$n.bodies" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT" CONSOLE_PAGES_URL="http://127.0.0.1:$PORT"
  W="$n"
  jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES
    ('tracker_adapter.demo-board','board','t','test','2026-11-24T00:00:00Z')"
}
jsql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
cget() { curl -sS -X POST "$JOBS_URL/__cget" --data-binary "$1"; }
# setrow <value> — an operator row (actor test), or `-` for no row.
setrow() {
  if [ "$1" = - ]; then jsql "DELETE FROM settings WHERE key='console.needs.sweep_dry_run'"
  else jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES
    ('console.needs.sweep_dry_run','$1','t','test','2026-11-24T00:00:00Z')"; fi
}
stage_of() { cget "SELECT stage FROM builds WHERE id = $1" | jq -r '.[0].stage'; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/needs-sweep.log"; : > "$T/gh-calls.txt"; scratch_rm "$H/state/alerts"; scratch_rm "$H/state/alert-line-sent"; }
RUNSEQ=0
run() { RUNSEQ=$((RUNSEQ+1)); NS_NOW=$((NOW + RUNSEQ)) "$H/$SCRIPT_REL" "$@" > "$T/run.out" 2>&1; RC=$?; }
summary() { grep ' summary ' "$H/logs/needs-sweep.log" | tail -1 | sed 's/.* summary //'; }
cands() { grep -c '^GET /api/needs-sweep/candidates' "$T/$1.log"; }
applies_true() { jq -s '[.[] | select(.apply == true)] | length' "$T/$1.bodies"; }
alerts() { grep -c 'needs-sweep-settings' "$H/logs/ALERTS.log"; }
ledger_n() { jget "SELECT COUNT(*) n FROM ledgers WHERE kind='needs_sweep'" | jq -r '.[0].n'; }

srv a1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: server did not start: $(cat "$T/a1.err")"; exit 1; }

# --- A1: no row -> apply ------------------------------------------------------
setrow -; RESET; run
[ "$RC" = 0 ] && ok "A1 rc 0" || bad "A1 rc $RC: $(cat "$T/run.out")"
grep -q '^mode=apply ' <<<"$(summary)" && ok "A1 no row: summary mode=apply" || bad "A1 summary: $(summary)"
[ "$(applies_true a1)" -ge 1 ] && ok "A1 an apply:true POST" || bad "A1 apply bodies: $(head -c 300 "$T/a1.bodies")"
[ "$(stage_of 1)" = stale ] && ok "A1 the aged row moved to stale" || bad "A1 row 1 is $(stage_of 1)"
[ "$(stage_of 2)" = plan_blocked ] && ok "A1 the young row is kept" || bad "A1 row 2 is $(stage_of 2)"
[ ! -s "$H/logs/ALERTS.log" ] && ok "A1 no alert" || bad "A1 alerted: $(cat "$H/logs/ALERTS.log")"

# --- A2: row 1 -> dry (the kill flag) -----------------------------------------
srv a2; setrow 1; RESET; run
[ "$RC" = 0 ] && ok "A2 rc 0" || bad "A2 rc $RC"
grep -q '^mode=dry ' <<<"$(summary)" && ok "A2 row 1: mode=dry" || bad "A2 summary: $(summary)"
[ "$(applies_true a2)" = 0 ] && ok "A2 no apply:true POST" || bad "A2 apply bodies: $(head -c 300 "$T/a2.bodies")"
[ "$(stage_of 1)" = plan_blocked ] && ok "A2 nothing changed" || bad "A2 row 1 is $(stage_of 1)"
[ "$(jget "SELECT value || ':' || actor v FROM settings WHERE key='console.needs.sweep_dry_run'" | jq -r '.[0].v')" = "1:test" ] \
  && ok "A2 the operator row is kept (1, actor test)" || bad "A2 row: $(jget "SELECT * FROM settings WHERE key='console.needs.sweep_dry_run'")"

# --- A3: closed port -> rc 4, one alert ---------------------------------------
srv a3; RESET; LB=$(ledger_n)
JOBS_URL="http://127.0.0.1:9" run
[ "$RC" = 4 ] && ok "A3 closed port: rc 4" || bad "A3 rc $RC: $(cat "$T/run.out")"
[ "$(alerts)" = 1 ] && [ "$(grep -c . "$H/logs/ALERTS.log")" = 1 ] && ok "A3 exactly one needs-sweep-settings alert" || bad "A3 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(cands a3)" = 0 ] && ok "A3 0 candidates GETs" || bad "A3 candidates GETs: $(cands a3)"
grep -q 'error: settings unreachable' "$H/logs/needs-sweep.log" && ok "A3 one error line in the log" || bad "A3 log: $(cat "$H/logs/needs-sweep.log")"
grep -q ' summary ' "$H/logs/needs-sweep.log" && bad "A3 an outage must not log a dry-run summary: $(summary)" || ok "A3 no dry-run summary"
[ "$(ledger_n)" = "$LB" ] && ok "A3 no ledger row" || bad "A3 ledger rows $LB -> $(ledger_n)"

# --- A4: jobs answers 500 -> rc 4, one alert ----------------------------------
cat > "$T/five.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
const s = createServer((req, res) => { appendFileSync(process.argv[2], `${req.method} ${req.url}\n`);
  res.writeHead(500, { 'content-type': 'application/json' }); res.end('{"error":"fixture 500"}'); });
s.listen(0, '127.0.0.1', () => process.stdout.write(`${s.address().port}\n`));
setTimeout(() => process.exit(0), 120e3).unref();
EOF
: > "$T/five.log"; : > "$T/five.port"
node "$T/five.mjs" "$T/five.log" > "$T/five.port" 2>/dev/null & PIDS+=("$!")
for _ in $(seq 1 200); do [ -s "$T/five.port" ] && break; sleep 0.05; done
FIVE=$(head -1 "$T/five.port")
srv a4; RESET
JOBS_URL="http://127.0.0.1:$FIVE" run
[ "$RC" = 4 ] && ok "A4 HTTP 500: rc 4" || bad "A4 rc $RC: $(cat "$T/run.out")"
[ "$(alerts)" = 1 ] && [ "$(grep -c . "$H/logs/ALERTS.log")" = 1 ] && ok "A4 exactly one alert" || bad "A4 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(cands a4)" = 0 ] && ok "A4 0 candidates GETs" || bad "A4 candidates GETs: $(cands a4)"
grep -q 'GET /api/settings/console.needs.sweep_dry_run' "$T/five.log" && ok "A4 the row was asked for" || bad "A4 five log: $(cat "$T/five.log")"

# --- A5: JOBS_URL="" -> not-configured ----------------------------------------
srv a5; RESET
JOBS_URL="" run
[ "$RC" = 0 ] && ok "A5 empty JOBS_URL: rc 0" || bad "A5 rc $RC: $(cat "$T/run.out")"
grep -q 'not-configured (no jobs client)' "$H/logs/needs-sweep.log" && ok "A5 not-configured line" || bad "A5 log: $(cat "$H/logs/needs-sweep.log")"
[ ! -s "$H/logs/ALERTS.log" ] && ok "A5 0 alerts" || bad "A5 alerted: $(cat "$H/logs/ALERTS.log")"
[ "$(cands a5)" = 0 ] && ok "A5 0 candidates GETs" || bad "A5 candidates GETs: $(cands a5)"

# --- A6: values that are not 0 or 1 -> apply (fallback 0) ---------------------
for v in junk ' 0' 10; do
  srv "a6$RUNSEQ"; setrow "$v"; RESET; run
  [ "$RC" = 0 ] && grep -q '^mode=apply ' <<<"$(summary)" && ok "A6 row '$v': apply" || bad "A6 row '$v': rc $RC $(summary)"
done

# --- A7: --dry-run wins over row 0 --------------------------------------------
srv a7; setrow 0; RESET; run --dry-run
grep -q '^mode=dry ' <<<"$(summary)" && [ "$(applies_true a7)" = 0 ] && [ "$(stage_of 1)" = plan_blocked ] \
  && ok "A7 --dry-run with row 0: dry, nothing changed" || bad "A7: $(summary) row1=$(stage_of 1)"

# --- A8: the untouched seed row moves on the first read -----------------------
srv a8
[ "$(jget "SELECT value || ':' || actor v FROM settings WHERE key='console.needs.sweep_dry_run'" | jq -r '.[0].v')" = "1:seed" ] \
  && ok "A8 the composed seed is 1, actor seed" || bad "A8 seed: $(jget "SELECT * FROM settings WHERE key='console.needs.sweep_dry_run'")"
RESET; run
grep -q '^mode=apply ' <<<"$(summary)" && ok "A8 seed row: the first run applies" || bad "A8 summary: $(summary)"
[ "$(jget "SELECT value || ':' || actor v FROM settings WHERE key='console.needs.sweep_dry_run'" | jq -r '.[0].v')" = "0:seed:BH-9556" ] \
  && ok "A8 the seed row moved to 0, actor seed:BH-9556" || bad "A8 row: $(jget "SELECT * FROM settings WHERE key='console.needs.sweep_dry_run'")"

[ -s "$T/gh-calls.txt" ] && bad "a GitHub read was made: $(cat "$T/gh-calls.txt")" || ok "0 GitHub calls"

echo "needs-sweep-acts.bh-9556: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
