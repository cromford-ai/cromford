#!/bin/bash
# tests/mc-budget.bh-6887-test.sh — BH-6887 (BH-6881.3): the merge conductor's
# daily re-review cap is a D1 counter (table mc_budget, routes
# POST /api/mc-budget/{take,give} in worker/jobs/src/routes/mc-budget.js),
# spent by headbound_review through mc_day_budget_take / _give
# (bin/lib/mc/locks.sh), and aged out by the mc_budget.age retention rule.
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/mc-budget.bh-6887.mjs).
#
#   B1  limit 2: two takes are granted (spent 1, 2), the third is denied; the
#       row holds spent 2 on the worker's day
#   B2  400 for a bad project, a bad kind, limit 0, "2x", 1000001, no limit;
#       no row is written; no bearer is 401
#   B3  give lowers spent by 1; a give at 0 keeps 0 (given:false); a bad day 400
#   B4  limit 1, two parallel takes: exactly one granted, spent 1; limit 3,
#       ten parallel takes: exactly three granted, spent 3
#   B5  EXPLAIN QUERY PLAN on 5,000 rows: the spend and the give use the
#       primary key; no plan SCANs mc_budget (run last: B9 would age out its
#       seed rows)
#   B6  mc_day_budget_take: rc 0 prints the day, then rc 3; mc_day_budget_give
#       rc 0; no worker rc 1; a 200 with no boolean granted rc 1
#   B7  headbound_review with REREVIEW_CAP=1: the first call spawns, the
#       second logs the cap and does not; with the D1 row reset to 0 and one
#       CAPFILE line it spawns (D1 decides); cap 0 makes no D1 call
#   B8  a spawn that fails (rc 3) gives the unit back; a 503 worker: the hub
#       counts CAPFILE (under it spawns, at it defers), a machine defers with
#       `could not be read`
#   B9  retention: a 40-day-old row goes, a 5-day-old row stays; the
#       retention_runs row of mc_budget.age has removed=1
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-budget.bh-6887-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
ROUTE="$DIR/worker/jobs/src/routes/mc-budget.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }
[ -f "$ROUTE" ] || bad "setup: no route module $ROUTE"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/locks"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
: > "$H/env/global.env"
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0

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
URL0="$JOBS_URL"
trap 'kill "$SPID" 2>/dev/null' EXIT

# post <op> <json> [out-file] — the status code; the body lands in the file.
post() { curl -sS -o "${3:-$T/out.json}" -w '%{http_code}' -X POST -H "authorization: Bearer $HARNESS_SECRET" \
  -H 'content-type: application/json' -d "$2" "$URL0/api/mc-budget/$1"; }
out() { jq -r "$1" "$T/out.json" 2>/dev/null; }
take() { jq -nc --arg p "$1" --arg k "$2" --argjson l "$3" '{project:$p,kind:$k,limit:$l}'; }
row() { curl -sS "$URL0/__row?project=$1&day=$2&kind=$3"; }
spent() { row "$1" "$2" "$3" | jq -r '.spent // "none"'; }
setrow() { curl -sS -X POST -d "$(jq -nc --arg p "$1" --arg d "$2" --arg k "$3" --argjson s "$4" '{project:$p,day:$d,kind:$k,spent:$s}')" "$URL0/__budget" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$URL0/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$URL0/__answer" > /dev/null; }
# The worker's UTC day, from its own take answer (a box never sends a time).
post take "$(take day-probe probe 1)" > /dev/null; DAY=$(out .day)

# ============================================================================
echo "B1: take with limit 2"
C=$(post take "$(take b1 rereview 2)"); A="$C $(out .granted) $(out .spent) $(out .day)"
C=$(post take "$(take b1 rereview 2)"); A="$A | $C $(out .granted) $(out .spent)"
C=$(post take "$(take b1 rereview 2)"); A="$A | $C $(out .granted) $(out .spent)"
[ "$A" = "200 true 1 $DAY | 200 true 2 | 200 false null" ] && ok "B1 granted spent 1, granted spent 2, denied" || bad "B1: $A"
[ "$(spent b1 "$DAY" rereview)" = 2 ] && ok "B1 the row holds spent 2 on day $DAY" || bad "B1 row: $(row b1 "$DAY" rereview)"
C=$(post take "$(take b1 rebase 2)")
[ "$C" = 200 ] && [ "$(out .spent)" = 1 ] && ok "B1 another kind has its own counter" || bad "B1 kind: $C $(cat "$T/out.json")"

# ============================================================================
echo "B2: bad requests are 400 and write nothing"
for B in '{"project":"bad project","kind":"rereview","limit":2}' '{"project":"b2","kind":"Re Review","limit":2}' \
         '{"project":"b2","kind":"rereview","limit":0}' '{"project":"b2","kind":"rereview","limit":"2x"}' \
         '{"project":"b2","kind":"rereview","limit":1000001}' '{"project":"b2","kind":"rereview"}' \
         '{"project":"b2","kind":"rereview","limit":true}' 'null'; do
  C=$(post take "$B")
  [ "$C" = 400 ] && ok "B2 400: $B" || bad "B2 $B answered $C $(cat "$T/out.json")"
done
[ "$(row b2 "$DAY" rereview)" = null ] && ok "B2 no row was written" || bad "B2 row: $(row b2 "$DAY" rereview)"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$(take b2 rereview 2)" "$URL0/api/mc-budget/take")
[ "$C" = 401 ] && ok "B2 no bearer: 401" || bad "B2 no bearer: $C"
[ "$(row b2 "$DAY" rereview)" = null ] && ok "B2 the unauthorised take wrote nothing" || bad "B2 row after 401: $(row b2 "$DAY" rereview)"

# ============================================================================
echo "B3: give"
give() { jq -nc --arg p "$1" --arg k "$2" --arg d "$3" '{project:$p,kind:$k,day:$d}'; }
C=$(post give "$(give b1 rereview "$DAY")")
[ "$C" = 200 ] && [ "$(out .given)" = true ] && [ "$(spent b1 "$DAY" rereview)" = 1 ] && ok "B3 give: spent 2 -> 1" || bad "B3: $C $(cat "$T/out.json") $(row b1 "$DAY" rereview)"
post give "$(give b1 rereview "$DAY")" > /dev/null
C=$(post give "$(give b1 rereview "$DAY")")
[ "$C" = 200 ] && [ "$(out .given)" = false ] && [ "$(spent b1 "$DAY" rereview)" = 0 ] && ok "B3 a give at 0 keeps 0 (given:false)" || bad "B3 at 0: $C $(cat "$T/out.json") $(row b1 "$DAY" rereview)"
C=$(post give '{"project":"b1","kind":"rereview","day":"17-10-2026"}')
[ "$C" = 400 ] && ok "B3 a bad day: 400" || bad "B3 bad day: $C"

# ============================================================================
echo "B4: parallel takes of the last unit"
par() { # par <project> <limit> <n> — n takes at once; prints the granted count
  local i
  for i in $(seq 1 "$3"); do post take "$(take "$1" rereview "$2")" "$T/par-$1-$i.json" > /dev/null & done
  wait
  cat "$T"/par-"$1"-*.json | jq -s '[.[] | select(.granted == true)] | length'
}
G=$(par b4a 1 2)
[ "$G" = 1 ] && [ "$(spent b4a "$DAY" rereview)" = 1 ] && ok "B4 limit 1, 2 parallel takes: exactly 1 granted, spent 1" || bad "B4a granted $G row $(row b4a "$DAY" rereview)"
G=$(par b4b 3 10)
[ "$G" = 3 ] && [ "$(spent b4b "$DAY" rereview)" = 3 ] && ok "B4 limit 3, 10 parallel takes: exactly 3 granted, spent 3" || bad "B4b granted $G row $(row b4b "$DAY" rereview)"

# ============================================================================
echo "B6: the shell client"
LIB=". '$H/bin/lib/merge-conductor-lib.sh' >/dev/null 2>&1; mc_init >/dev/null 2>&1"
R=$(bash -c "$LIB; mc_day_budget_take b6 rereview 1; echo \"rc=\$?\"; mc_day_budget_take b6 rereview 1; echo \"rc=\$?\"; mc_day_budget_give b6 rereview $DAY; echo \"rc=\$?\"" | tr '\n' ' ')
[ "$R" = "$DAY rc=0 rc=3 rc=0 " ] && ok "B6 take rc 0 prints $DAY, then rc 3; give rc 0" || bad "B6: $R"
[ "$(spent b6 "$DAY" rereview)" = 0 ] && ok "B6 the give round-trips on the take's day" || bad "B6 row: $(row b6 "$DAY" rereview)"
R=$(JOBS_URL="" bash -c "$LIB; mc_day_budget_take b6 rereview 1; echo \"rc=\$?\"" | tr '\n' ' ')
[ "$R" = "rc=1 " ] && ok "B6 no worker: rc 1" || bad "B6 no worker: $R"
for A in '{"day":"'"$DAY"'"}' '{"granted":"true","day":"'"$DAY"'"}' '{"granted":true,"day":"today"}'; do
  answer "$(jq -nc --arg b "$A" '{path_prefix:"/api/mc-budget/",status:200,body:$b}')"
  R=$(bash -c "$LIB; mc_day_budget_take b6 rereview 1; echo \"rc=\$?\"" | tr '\n' ' ')
  [ "$R" = "rc=1 " ] && ok "B6 a 200 of $A: rc 1, not a grant" || bad "B6 $A: $R"
done
answer '{}'

# ============================================================================
echo "B7: the cap through headbound_review"
P7=demo-os; K7=example-org/demo-os#71; U7=https://github.com/example-org/demo-os/pull/71
CAPF="$T/cap.txt"
# hb [env...] — one headbound_review of #71 with the spawn and its neighbours
# stubbed; prints `spawned` per spawn and the rc.
hb() {
  ( . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    CAPFILE="$CAPF"; REREVIEW_CAP="${CAP:-1}"; REREVIEW_BUDGET=5; MC_TICK_ID="b7-${TICK:-1}"
    mc_job_running() { return 1; }
    mc_lane_next_review_account() { echo fixture-acct; }
    mc_lane_down_for_account() { return 1; }
    mc_rereview_spawn() { echo spawned >> "$T/spawns.txt"; return "${SPAWN_RC:-0}"; }
    headbound_review provenance "$K7" example-org/demo-os 71 "$P7" "$U7" - "${HEAD7:-7171717171717171717171717171717171717171}" - "" CLEAN green
    echo "rc=$?" )
}
: > "$CAPF"; : > "$T/spawns.txt"; : > "$H/logs/merge-conductor.log"
TICK=1 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && ok "B7 the first call spawns" || bad "B7 first: spawns $(wc -l < "$T/spawns.txt"); log: $(tail -3 "$H/logs/merge-conductor.log")"
[ "$(spent $P7 "$DAY" rereview)" = 1 ] && ok "B7 the D1 counter is 1" || bad "B7 row: $(row $P7 "$DAY" rereview)"
: > "$CAPF"
TICK=2 HEAD7=7272727272727272727272727272727272727272 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && grep -q "$K7 re-review deferred — $P7 hit the operator-set daily cap (1)" "$H/logs/merge-conductor.log" \
  && ok "B7 the second call, CAPFILE emptied: the D1 counter defers it" || bad "B7 second: spawns $(wc -l < "$T/spawns.txt"); log: $(tail -3 "$H/logs/merge-conductor.log")"
setrow $P7 "$DAY" rereview 0
echo "$P7 $K7 7171717171717171717171717171717171717171" > "$CAPF"
: > "$H/logs/merge-conductor.log"
TICK=3 HEAD7=7373737373737373737373737373737373737373 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 2 ] && ! grep -q 'daily cap' "$H/logs/merge-conductor.log" \
  && ok "B7 D1 row reset to 0, CAPFILE at the cap: D1 decides, it spawns" || bad "B7 third: spawns $(wc -l < "$T/spawns.txt"); log: $(tail -3 "$H/logs/merge-conductor.log")"
[ "$(wc -l < "$CAPF")" = 2 ] && ok "B7 a granted spawn still appends its CAPFILE line" || bad "B7 capfile: $(cat "$CAPF")"
: > "$T/srv.log"; setrow $P7 "$DAY" rereview 0
TICK=4 CAP=0 HEAD7=7474747474747474747474747474747474747474 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 3 ] && ! grep -q '/api/mc-budget/' "$T/srv.log" && ok "B7 cap 0: it spawns and makes no D1 call" \
  || bad "B7 cap 0: spawns $(wc -l < "$T/spawns.txt"); srv: $(grep mc-budget "$T/srv.log")"

# ============================================================================
echo "B8: a failed spawn gives the unit back; a 503 worker"
setrow $P7 "$DAY" rereview 0; : > "$CAPF"; : > "$T/spawns.txt"
TICK=5 SPAWN_RC=3 HEAD7=7575757575757575757575757575757575757575 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && [ "$(spent $P7 "$DAY" rereview)" = 0 ] && [ ! -s "$CAPF" ] \
  && ok "B8 spawn rc 3: the D1 unit is given back (spent 0), no CAPFILE line" || bad "B8 give: spawns $(wc -l < "$T/spawns.txt") row $(row $P7 "$DAY" rereview) cap $(cat "$CAPF")"
answer '{"path_prefix":"/api/mc-budget/","status":503,"body":"{\"error\":\"mc_budget unavailable\"}"}'
: > "$T/spawns.txt"; : > "$H/logs/merge-conductor.log"
TICK=6 HEAD7=7676767676767676767676767676767676767676 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && [ "$(wc -l < "$CAPF")" = 1 ] && ok "B8 503 on the hub, CAPFILE under the cap: it spawns and counts the box file" \
  || bad "B8 hub under: spawns $(wc -l < "$T/spawns.txt") cap $(cat "$CAPF"); log: $(tail -3 "$H/logs/merge-conductor.log")"
TICK=7 HEAD7=7777777777777777777777777777777777777777 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && grep -q "$K7 re-review deferred — $P7 hit the operator-set daily cap (1)" "$H/logs/merge-conductor.log" \
  && ok "B8 503 on the hub, CAPFILE at the cap: it defers" || bad "B8 hub at: spawns $(wc -l < "$T/spawns.txt"); log: $(tail -3 "$H/logs/merge-conductor.log")"
: > "$CAPF"; : > "$H/logs/merge-conductor.log"
TICK=8 MC_ON_MACHINE=1 HEAD7=7878787878787878787878787878787878787878 hb > /dev/null
[ "$(wc -l < "$T/spawns.txt")" = 1 ] && grep -q "$K7 re-review deferred — the daily cap counter could not be read" "$H/logs/merge-conductor.log" \
  && ok "B8 503 on a machine: it defers, could not be read" || bad "B8 machine: spawns $(wc -l < "$T/spawns.txt"); log: $(tail -3 "$H/logs/merge-conductor.log")"
grep -q 'operator-set daily cap' "$H/logs/merge-conductor.log" && bad "B8 the machine line says the cap was hit" || ok "B8 the machine line does not claim a full cap"
answer '{}'

# ============================================================================
echo "B9: retention of mc_budget"
ago() { date -u -d "@$(( $(date -u +%s) - $1 * 86400 ))" +%Y-%m-%d; }
OLD=$(ago 40); NEW=$(ago 5)
setrow b9 "$OLD" rereview 3; setrow b9 "$NEW" rereview 2
setting retention.dry_run 0
C=$(curl -sS -o "$T/ret.json" -w '%{http_code}' -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d '{}' "$URL0/api/retention/run")
R=$(jq -c '.rules[] | select(.rule == "mc_budget.age") | {removed, error}' "$T/ret.json" 2>/dev/null)
[ "$C" = 200 ] && [ "$R" = '{"removed":1,"error":null}' ] && ok "B9 the run removed 1 mc_budget row" || bad "B9 run: $C $R $(head -c 300 "$T/ret.json")"
RR=$(curl -sS "$URL0/__runs?rule=mc_budget.age" | jq -c '[.[] | {dry_run, removed}]')
[ "$RR" = '[{"dry_run":0,"removed":1}]' ] && ok "B9 one retention_runs row for mc_budget.age, removed=1" || bad "B9 retention_runs: $RR"
[ "$(row b9 "$OLD" rereview)" = null ] && [ "$(spent b9 "$NEW" rereview)" = 2 ] && ok "B9 the 40-day row is gone, the 5-day row stays" \
  || bad "B9 rows: old $(row b9 "$OLD" rereview) new $(row b9 "$NEW" rereview)"

# ============================================================================
echo "B5: EXPLAIN QUERY PLAN of the statements on 5,000 rows (last: its seed rows would be B9's)"
E=$(curl -sS "$URL0/__eqp")
for k in spend give; do
  P=$(jq -r --arg k "$k" '.[$k] | join(" | ")' <<<"$E" 2>/dev/null)
  if grep -qE 'sqlite_autoindex_mc_budget_1|PRIMARY KEY' <<<"$P" && ! grep -q 'SCAN mc_budget' <<<"$P"; then
    ok "B5 $k uses the primary key: $P"
  else bad "B5 $k plan: ${P:-$E}"; fi
done

echo "mc-budget: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
