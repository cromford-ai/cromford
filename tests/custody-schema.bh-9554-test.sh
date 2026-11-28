#!/bin/bash
# tests/custody-schema.bh-9554-test.sh — BH-9554 (custody C0): the custody
# tables, their indexes, settings rows and retention rules, on the composed
# jobs schema (worker/jobs/schema.d/*-bh-9554-custody.sql) in node:sqlite,
# through the REAL jobs worker (tests/lib/custody.bh-9554.mjs) and the routes in
# worker/jobs/src/routes/custody.js and
# worker/jobs/src/routes/retention.d/bh-9554-custody.js. 0 vendor calls.
#
#   S1 ticket_custody has every ticket column plus due_at, rev, settled_at,
#      created_at, and UNIQUE(project, ticket); custody_actions has
#      actor/action/why/result/at; each custody.* settings row holds its seed;
#      custody.deadline.building_min "x" -> the code default 180, 5 -> now+5 min
#   S2 50,000 seeded rows: EXPLAIN QUERY PLAN of the exported DUE_SQL uses
#      idx_ticket_custody_due, ROW_SQL the UNIQUE autoindex, GAPS_SQL the two
#      open-row indexes, the retention id reads their indexes; no plan SCANs
#      ticket_custody or custody_actions. GET /api/custody/due?limit=5: 5 rows,
#      oldest due first, truncated:true, no settled row
#   S3 a claim, a next and a release each add one custody_actions row with
#      the right actor and action; a refused claim adds none
#   S4 retention: with retention.dry_run=1 nothing is deleted and the settled
#      row past the window is counted; with 0 only the row settled 10 days ago
#      goes (not the one settled 1 day ago, not the open one); one
#      retention_runs row per run for ticket_custody.settled
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/custody-schema.bh-9554-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/custody-fixture.bh-9554.sh
. "$(dirname "$0")/lib/custody-fixture.bh-9554.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
custody_fixture_start
# The worker imports composed catalogs that are never committed (BH-6540).
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1

# The files these three suites pin (D41: every new source is named on a
# non-comment line of a suite).
SOURCES=("$CF_REPO/worker/jobs/src/routes/custody.js" "$CF_REPO/worker/jobs/src/routes/retention.d/bh-9554-custody.js"
  "$CF_REPO/worker/jobs/schema.d/202611121607-bh-9554-custody.sql" "$CF_REPO/worker/jobs/test/route-table.d/bh-9554-custody.txt"
  "$CF_REPO/worker/jobs/src/lib/archive.js" "$CF_REPO/worker/jobs/test/custody.bh-9554.test.js"
  "$CF_REPO/bin/lib/jobs/custody.sh" "$CF_REPO/bin/jobs-client.d/bh-9554-custody.sh"
  "$CF_REPO/tests/lib/custody.bh-9554.mjs" "$CF_REPO/tests/lib/custody-fixture.bh-9554.sh")
for f in "${SOURCES[@]}"; do [ -f "$f" ] || bad "missing source ${f#"$CF_REPO"/}"; done

api() { # api <method> <path> [json] — the status; the body in $T/api.json
  if [ -n "${3:-}" ]; then
    curl -sS -o "$T/api.json" -w '%{http_code}' -X "$1" -H "authorization: Bearer $HARNESS_SECRET" \
      -H 'content-type: application/json' -d "$3" "$JOBS_URL$2"
  else
    curl -sS -o "$T/api.json" -w '%{http_code}' -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2"
  fi
}
sql() { hook POST /__sql "$(jq -nc --arg s "$1" '{sql:$s}')"; }
setting() { hook PUT /__setting "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" > /dev/null; }
P=schema-p

# ============================================================================
echo "S1: columns, the unique key, the settings rows"
COLS=$(hook GET '/__columns?table=ticket_custody' | jq -r '[.[].name] | join(" ")')
for c in project ticket state owner_lane lease_expires_at next_action deadline_at attempt ladder_rung last_evidence pr_number updated_at due_at rev settled_at created_at; do
  [[ " $COLS " == *" $c "* ]] && ok "S1 ticket_custody.$c" || bad "S1 no ticket_custody.$c in: $COLS"
done
ACOLS=$(hook GET '/__columns?table=custody_actions' | jq -r '[.[].name] | join(" ")')
for c in project ticket actor action why result at; do
  [[ " $ACOLS " == *" $c "* ]] && ok "S1 custody_actions.$c" || bad "S1 no custody_actions.$c in: $ACOLS"
done
hook GET '/__indexes?table=ticket_custody' | jq -e '[.[] | select(.unique == 1 and .origin == "u")] | length == 1' > /dev/null \
  && ok "S1 one UNIQUE constraint index" || bad "S1 indexes: $(hook GET '/__indexes?table=ticket_custody')"
sql "INSERT INTO ticket_custody (project,ticket,state,created_at,updated_at) VALUES ('$P','DUP','building','x','x')" > /dev/null
R=$(sql "INSERT INTO ticket_custody (project,ticket,state,created_at,updated_at) VALUES ('$P','DUP','building','x','x')")
grep -qi 'unique' <<<"$R" && ok "S1 a second (project, ticket) row is refused" || bad "S1 dup insert: $R"
sql "DELETE FROM ticket_custody WHERE ticket='DUP'" > /dev/null
while read -r k v; do
  got=$(hook GET "/__setting?key=$k" | jq -r '.value // "MISSING"')
  [ "$got" = "$v" ] && ok "S1 $k = $v" || bad "S1 $k = $got, want $v"
done <<'EOF'
custody.lease_s 1800
custody.lease_max_s 86400
custody.deadline.triaged_min 120
custody.deadline.planned_min 120
custody.deadline.plan_blocked_min 1440
custody.deadline.building_min 180
custody.deadline.pr_open_min 1440
custody.deadline.in_queue_min 120
custody.deadline.ejected_min 30
custody.deadline.abandoned_min 60
custody.deadline_max_min 43200
custody.due.limit 200
retention.ticket_custody.settled_days 7
retention.custody_actions.days 90
EOF
secs() { jq -r '((.row.deadline_at|fromdate) - (.row.updated_at|fromdate))' "$T/api.json"; }
claim() { api POST /api/custody/claim "$(jq -nc --arg p "$P" --arg k "$1" --arg l "$2" --arg s "$3" '{project:$p,ticket:$k,lane:$l,state:$s,next_action:"reoffer"}')"; }
setting custody.deadline.building_min x
C=$(claim "$(uniq_key s1a)" pool building)
[ "$C" = 200 ] && [ "$(secs)" = 10800 ] && ok "S1 building_min 'x': the code default 180 min" || bad "S1 x: $C $(cat "$T/api.json")"
setting custody.deadline.building_min 5
C=$(claim "$(uniq_key s1b)" pool building)
[ "$C" = 200 ] && [ "$(secs)" = 300 ] && ok "S1 building_min 5: now + 5 min" || bad "S1 5: $C $(cat "$T/api.json")"
setting custody.deadline.building_min 180

# ============================================================================
echo "S2: EXPLAIN QUERY PLAN at 50,000 rows"
hook POST /__seed '{"n":50000,"projects":8}' > "$T/seed.json"
[ "$(jq -r .seeded "$T/seed.json")" = 50000 ] && ok "S2 50,000 rows seeded" || bad "S2 seed: $(cat "$T/seed.json")"
hook GET /__explain > "$T/eqp.json"
has() { jq -e --arg k "$1" --arg s "$2" '[.[$k][] | select(contains($s))] | length > 0' "$T/eqp.json" > /dev/null; }
has due 'SEARCH ticket_custody USING INDEX idx_ticket_custody_due (due_at<?)' && ok "S2 due SEARCHes idx_ticket_custody_due" || bad "S2 due: $(jq -c .due "$T/eqp.json")"
has row 'USING INDEX sqlite_autoindex_ticket_custody_1 (project=? AND ticket=?)' && ok "S2 row uses the UNIQUE autoindex" || bad "S2 row: $(jq -c .row "$T/eqp.json")"
has gaps_owner idx_ticket_custody_open_owner && ok "S2 gaps no_owner uses idx_ticket_custody_open_owner" || bad "S2 gaps owner: $(jq -c .gaps_owner "$T/eqp.json")"
has gaps_deadline idx_ticket_custody_open_deadline && ok "S2 gaps no_deadline uses idx_ticket_custody_open_deadline" || bad "S2 gaps deadline: $(jq -c .gaps_deadline "$T/eqp.json")"
has gaps_project_owner idx_ticket_custody_open_owner && ok "S2 gaps per project, owner index" || bad "S2 gp owner: $(jq -c .gaps_project_owner "$T/eqp.json")"
has gaps_project_deadline idx_ticket_custody_open_deadline && ok "S2 gaps per project, deadline index" || bad "S2 gp deadline: $(jq -c .gaps_project_deadline "$T/eqp.json")"
jq -e '.retention["ticket_custody.settled"] | map(select(contains("idx_ticket_custody_settled"))) | length > 0' "$T/eqp.json" > /dev/null \
  && ok "S2 retention ticket_custody.settled uses idx_ticket_custody_settled" || bad "S2 ret settled: $(jq -c .retention "$T/eqp.json")"
jq -e '.retention["custody_actions.age"] | map(select(contains("idx_custody_actions_at"))) | length > 0' "$T/eqp.json" > /dev/null \
  && ok "S2 retention custody_actions.age uses idx_custody_actions_at" || bad "S2 ret actions: $(jq -c .retention "$T/eqp.json")"
jq -e '[.. | strings | select(test("^SCAN (ticket_custody|custody_actions)\\b"))] | length == 0' "$T/eqp.json" > /dev/null \
  && ok "S2 no plan SCANs ticket_custody or custody_actions" || bad "S2 scans: $(jq -c '[.. | strings | select(test("SCAN"))]' "$T/eqp.json")"
jq -e '[.. | strings | select(test("TEMP B-TREE"))] | length == 0' "$T/eqp.json" > /dev/null \
  && ok "S2 no plan sorts in a temp B-tree" || bad "S2 sorts: $(jq -c '[.. | strings | select(test("TEMP"))]' "$T/eqp.json")"
C=$(api GET '/api/custody/due?limit=5')
[ "$C" = 200 ] && [ "$(jq '.rows | length' "$T/api.json")" = 5 ] && [ "$(jq -r .truncated "$T/api.json")" = true ] \
  && ok "S2 due?limit=5: 5 rows, truncated:true" || bad "S2 due: $C $(head -c 300 "$T/api.json")"
jq -e '[.rows[].due_at] as $d | $d == ($d | sort)' "$T/api.json" > /dev/null && ok "S2 oldest due first" || bad "S2 order: $(jq -c '[.rows[].due_at]' "$T/api.json")"
jq -e '[.rows[] | select(.settled_at != null)] | length == 0' "$T/api.json" > /dev/null && ok "S2 no settled row" || bad "S2 settled rows in due"
MIN=$(sql "SELECT MIN(due_at) AS m FROM ticket_custody WHERE settled_at IS NULL" | jq -r '.[0].m')
[ "$(jq -r '.rows[0].due_at' "$T/api.json")" = "$MIN" ] && ok "S2 the first row is the oldest due of all 50,000" || bad "S2 first $(jq -r '.rows[0].due_at' "$T/api.json") want $MIN"

# ============================================================================
echo "S3: one action row per accepted write"
K=$(uniq_key s3)
acts() { hook GET "/__actions?project=$P&ticket=$K" | jq -c '[.[] | [.actor, .action]]'; }
claim "$K" pool building > /dev/null
[ "$(acts)" = '[["pool","claim"]]' ] && ok "S3 claim: one row, pool claim" || bad "S3 claim: $(acts)"
C=$(claim "$K" triage triaged)
[ "$C" = 409 ] && [ "$(acts)" = '[["pool","claim"]]' ] && ok "S3 a refused claim adds none" || bad "S3 refused: $C $(acts)"
api POST /api/custody/next "$(jq -nc --arg p "$P" --arg k "$K" '{project:$p,ticket:$k,lane:"pool",next_action:"wait",evidence:"waiting on CI"}')" > /dev/null
api POST /api/custody/release "$(jq -nc --arg p "$P" --arg k "$K" '{project:$p,ticket:$k,lane:"pool",next_action:"retriage"}')" > /dev/null
[ "$(acts)" = '[["pool","claim"],["pool","next"],["pool","release"]]' ] && ok "S3 next and release: one row each" || bad "S3 next/release: $(acts)"
W=$(hook GET "/__actions?project=$P&ticket=$K" | jq -r '.[1].why')
[ "$W" = "waiting on CI" ] && ok "S3 why carries the evidence" || bad "S3 why: $W"
hook GET "/__actions?project=$P&ticket=$K" | jq -e 'all(.[]; (.result | length) > 0 and (.at | length) == 20)' > /dev/null \
  && ok "S3 every row has a result and an ISO at" || bad "S3 rows: $(hook GET "/__actions?project=$P&ticket=$K")"

# ============================================================================
echo "S4: retention deletes only settled rows past the window"
sql "DELETE FROM ticket_custody" > /dev/null
ago() { jq -rn --argjson d "$1" 'now - $d * 86400 | floor | todate'; }
ins() { # ins <ticket> <settled_at|NULL> <updated_at>
  local s="NULL"; [ "$2" = NULL ] || s="'$2'"
  sql "INSERT INTO ticket_custody (project,ticket,state,settled_at,created_at,updated_at) VALUES ('$P','$1','merged',$s,'$3','$3')" > /dev/null
}
ins R-old "$(ago 10)" "$(ago 10)"
ins R-new "$(ago 1)" "$(ago 1)"
ins R-open NULL "$(ago 30)"
left() { sql "SELECT ticket FROM ticket_custody WHERE project='$P' ORDER BY ticket" | jq -r '[.[].ticket] | join(" ")'; }
runs() { sql "SELECT dry_run, counted, removed FROM retention_runs WHERE rule='ticket_custody.settled' ORDER BY rowid" | jq -c '[.[] | [.dry_run, .counted, .removed]]'; }
setting retention.dry_run 1
C=$(api POST /api/retention/run '{}')
[ "$C" = 200 ] && [ "$(left)" = "R-new R-old R-open" ] && ok "S4 dry run deletes nothing" || bad "S4 dry: $C left=$(left) $(head -c 300 "$T/api.json")"
[ "$(runs)" = '[[1,1,0]]' ] && ok "S4 dry run: one audit row, 1 counted" || bad "S4 dry audit: $(runs)"
setting retention.dry_run 0
C=$(api POST /api/retention/run '{}')
[ "$C" = 200 ] && [ "$(left)" = "R-new R-open" ] && ok "S4 real run: only the row settled 10 days ago is gone" || bad "S4 real: $C left=$(left)"
[ "$(runs)" = '[[1,1,0],[0,1,1]]' ] && ok "S4 real run: one more audit row, 1 removed" || bad "S4 real audit: $(runs)"
setting retention.dry_run 1

# ============================================================================
echo "W: the worker unit suite (the claim, 400, act and due tables)"
( cd "$CF_REPO/worker/jobs" && node --test "$CF_REPO/worker/jobs/test/custody.bh-9554.test.js" ) > "$T/unit.txt" 2>&1
URC=$?
[ "$URC" = 0 ] && grep -q '^# fail 0' "$T/unit.txt" && ok "W node --test worker/jobs/test/custody.bh-9554.test.js" || bad "W rc=$URC $(grep -E '^not ok|^# (pass|fail)' "$T/unit.txt")"

echo "custody-schema: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
