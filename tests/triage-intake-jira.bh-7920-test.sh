#!/bin/bash
# tests/triage-intake-jira.bh-7920-test.sh — BH-7920: the real
# bin/triage-gate.sh reads a Jira project through the tracker contract. The
# Jira gateway stub (tests/lib/tracker-jira-stub.sh) plays this ticket's
# fixtures (tests/fixtures/triage-intake.bh-7920/jira/): its search page holds
# SCRUM-12 (To Do, ai-build), SCRUM-13 (Done, ai-build) and SCRUM-14 (no
# label), and it serves that page whatever the JQL says.
#
#   J-I1 --pending exits 0
#   J-I2 the pending file's .jira holds exactly SCRUM-12
#   J-I3 SCRUM-13 and SCRUM-14 are absent
#   J-I4 --thread SCRUM-12 prints its comments
#   J-I5 --buildable SCRUM-12 prints OK
#   J-I6 the allowlist refusal: --thread CLNT-5 exits 1 with nothing printed,
#        --buildable-strict CLNT-5 is BLOCKED unreadable, and CLNT is never asked
#   J-I7 a context that does not load (JIRA_API_TOKEN removed): --pending exits
#        1, plain mode is SKIP token-unresolved, one ALERTS line over two runs
#   HARNESS_TEST_SANDBOX=1 bash tests/triage-intake-jira.bh-7920-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

jira_stub_setup "$T" || { echo "stub setup failed"; exit 1; }
export JIRA_STUB_FIX="$DIR/tests/fixtures/triage-intake.bh-7920/jira"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
jproj  o/j  https://j.example  -  9
CONF
export FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0
jira_unset tracker_jira.jproj.write_projects
jira_unset tracker_jira.jproj.comment_projects
jira_unset tracker_jira.jproj.waiting_on_field
jira_unset tracker_jira.jproj.triage_verdict_field
jira_set tracker_jira.jproj.read_projects SCRUM
S="$JIRA_STUB_STATE"; H="$T/h"; GATE="$DIR/bin/triage-gate.sh"
gate() { "$GATE" jproj "$@" 2>>"$T/gate.err"; }

# J-I1 .. J-I3
rm -f "$S/requests"
gate --pending; rc=$?
P="$H/state/jproj.gate.pending"
[ "$rc" = 0 ] && [ -s "$P" ] && ok || bad "J-I1 --pending must exit 0 and write the pending file (rc=$rc)"
[ "$(jq -c '[.jira[] | .id]' "$P" 2>/dev/null)" = '["SCRUM-12"]' ] && ok || bad "J-I2 .jira must hold exactly SCRUM-12: $(cat "$P" 2>/dev/null)"
[ "$(jq -c '.jira[0] | [.key, .updatedAt, .commentCount, .state]' "$P" 2>/dev/null)" = '["SCRUM-12","2026-10-21T09:15:00Z",2,"open"]' ] \
  && ok || bad "J-I2 SCRUM-12's row: $(jq -c '.jira[0]' "$P" 2>/dev/null)"
grep -qE 'SCRUM-13|SCRUM-14' "$P" && bad "J-I3 a Done or unlabeled issue reached the pending file" || ok
jql=$(jq -r .jql "$S/search-req-1.json" 2>/dev/null)
[ "$jql" = 'project in ("SCRUM") AND labels = "ai-build" AND statusCategory != Done ORDER BY updated DESC' ] && ok || bad "J-I3 the search asked for open ai-build issues: $jql"
[ ! -s "$S/gh.log" ] && ok || bad "J-I1 the gate called gh: $(cat "$S/gh.log")"

# J-I4 --thread
out=$(gate --thread SCRUM-12); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.doc.comments[].body]' 2>/dev/null)" = '["Can it include the fee column?","Yes, add the fee column too."]' ] \
  && ok || bad "J-I4 --thread SCRUM-12 must print its comments (rc=$rc): $out"
out=$(gate --signal SCRUM-12); grep -qxE '[0-9a-f]{16}' <<<"$out" && ok || bad "J-I4 --signal SCRUM-12: $out"

# J-I5 --buildable
[ "$(gate --buildable SCRUM-12)" = OK ] && ok || bad "J-I5 --buildable SCRUM-12: $(gate --buildable SCRUM-12)"

# J-I6 the allowlist refusal
rm -f "$S/requests"
out=$(gate --thread CLNT-5); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "J-I6 --thread CLNT-5 must exit 1 with nothing (rc=$rc out=$out)"
[ "$(gate --buildable-strict CLNT-5)" = "BLOCKED unreadable" ] && ok || bad "J-I6 --buildable-strict CLNT-5"
[ "$(jira_req_count CLNT)" = 0 ] && ok || bad "J-I6 CLNT was asked: $(jira_requests)"

# J-I7 a context that does not load
cp "$H/env/jproj.env" "$T/jproj.env.good"
grep -v '^JIRA_API_TOKEN=' "$T/jproj.env.good" > "$H/env/jproj.env"
rm -f "$P" "$S/requests"; : > "$H/logs/ALERTS.log"
gate --pending; rc=$?
[ "$rc" = 1 ] && [ ! -e "$P" ] && ok || bad "J-I7 --pending must exit 1 and write nothing (rc=$rc)"
echo 9999999999 > "$H/state/jproj.gate-meta"   # the daily sweep is not due
out=$(gate); [ "$out" = "SKIP token-unresolved" ] && ok || bad "J-I7 plain mode: $out"
[ "$(grep -c 'jproj' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "J-I7 exactly one ALERTS line over two runs: $(cat "$H/logs/ALERTS.log")"
[ "$(jira_req_count .)" = 0 ] && ok || bad "J-I7 a context that did not load must call no gateway: $(jira_requests)"
cp "$T/jproj.env.good" "$H/env/jproj.env"

LEAK=$(grep -rlF -- "$JIRA_TOKEN_FX" "$H/state" "$H/logs" "$S" "$T/gate.err" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the token reached: $LEAK"

echo "triage-intake-jira.bh-7920: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
