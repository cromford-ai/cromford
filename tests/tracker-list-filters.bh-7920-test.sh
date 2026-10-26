#!/bin/bash
# tests/tracker-list-filters.bh-7920-test.sh — BH-7920: tracker_list
# [--state open|all] [--label <name>] [--since <iso>] and the three row keys
# (updatedAt, state, commentCount), through bin/lib/tracker.sh against every
# adapter. Contract case C12 (tests/lib/tracker-contract-c12.bh-7920.sh) runs
# four times, then the per-adapter facts:
#
#   F1-F4 C12 (a)-(g) for github-issues, board, jira and linear
#   F5    no flag sends the request of today: the gh args, the board URLs,
#         the Jira JQL string, the Linear filter (nin, no $since)
#   F6    a Jira `+0300` time prints as UTC (`...T07:00:00Z`)
#   F7    Jira --since puts the day before in the JQL; the exact cut is ours
#   F8    Linear --state all has no nin part; --since declares and uses $since;
#         GitHub --state all --since are query params
#   F9    the Linear knob tracker_linear.<p>.list_comment_cap: 10 sends cc 10,
#         0 or 99 is rc 1 and sends nothing, no row sends 25, and a capped
#         comment page answers commentCount null
#
# Every stub serves its rows WHATEVER the request asks for, so what the list
# keeps is the contract's own check. No network: gh and curl are stubs, and no
# stub writes its argv where a key rides.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-list-filters.bh-7920-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-contract-c12.bh-7920.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
ok()  { _c12_ok; }
bad() { TC_FAIL=$((TC_FAIL+1)); echo "FAIL $1"; }

BTOK=tok-fixture-board-7920
LKEY=lin-api-fixture-sentinel-7920
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$T/run" "$T/gs" "$T/bs"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ghproj  o/r  https://gh.example     -           9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0 PATH="$T/stub:$PATH" GH_TOKEN=gh-fixture-7920
export TF_GS="$T/gs" TF_BS="$T/bs" TF_BTOK="$BTOK"

# ---- the GitHub stub: every call logged (argv carries no token), one list --
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
S="$TF_GS"
printf '%s\n' "$*" >> "$S/reqs"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "${2:-}"; exit 0; }
[ "$1 $2 $3" = "api -i -X" ] || exit 1
m="$4"; p="${5%%\?*}"; page=1
for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
[ "$m" = GET ] || { echo "$m $p" >> "$S/writes"; send 403 '{"message":"no writes here"}'; }
case "$p" in
  repos/o/r/issues) [ "$page" = 1 ] && send 200 "$(cat "$S/list.json")"; send 200 '[]' ;;
esac
send 404 '{"message":"Not Found"}'
SH
# ---- the board stub ----------------------------------------------------------
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TF_BS"; m=GET; url=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-o|-w|-m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$m" "$url" >> "$S/reqs"
[ "$auth" = "$TF_BTOK" ] || echo "badauth $url" >> "$S/authbad"
[ "$m" = GET ] || { echo "$m $url" >> "$S/writes"; exit 22; }
case "${url#https://board.example/api/board}" in
  /boards) printf '%s\n' '[{"id":"b1"}]' ;;
  /boards/b1/tickets) cat "$S/list.json" ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
SH
chmod +x "$T/stub/gh" "$T/stub/curl"

. "$DIR/bin/lib/tracker.sh" || exit 1
SINCE_GH=2026-10-21T00:00:00Z

# ---- GitHub ------------------------------------------------------------------
jq -n '[
  {number:201, title:"Open new", state:"open", labels:[{name:"ai-build"}], updated_at:"2026-10-21T10:00:00Z", comments:3, html_url:"https://github.com/o/r/issues/201"},
  {number:202, title:"Closed new", state:"closed", labels:[{name:"ai-build"}], updated_at:"2026-10-21T11:00:00Z", comments:0},
  {number:203, title:"Other label", state:"open", labels:[{name:"feature"}], updated_at:"2026-10-21T12:00:00Z", comments:1},
  {number:204, title:"Open old", state:"open", labels:[{name:"ai-build"}], updated_at:"2026-10-19T00:00:00Z", comments:5},
  {number:205, title:"No date", state:"open", labels:[{name:"ai-build"}], updated_at:null, comments:0},
  {number:206, title:"a PR", state:"open", labels:[{name:"ai-build"}], updated_at:"2026-10-21T12:00:00Z", pull_request:{url:"x"}}]' > "$T/gs/list.json"
tc12_setup_github_issues() {
  tracker_load github-issues || return 1
  TRK_SLUG=o/r; TRK_LOG="$T/run/gh.log"; TRK_DRY=0; TRK_REQ_FILE=""
  C12_OPEN=201; C12_CLOSED=202; C12_OTHER=203; C12_OLD=204; C12_NODATE=205; C12_SINCE="$SINCE_GH"
  C12_OPEN_UPDATED=2026-10-21T10:00:00Z; C12_OPEN_COMMENTS=3; C12_DROP_SINCE=""
}
c12_reqs()   { cat "$T/gs/reqs" 2>/dev/null | grep -c .; }
c12_writes() { cat "$T/gs/writes" 2>/dev/null; }
tracker_contract_c12 github-issues   # F1
# F5 + F8 (GitHub): the query params
rm -f "$T/gs/reqs"; tracker_list >/dev/null
l=$(head -1 "$T/gs/reqs")
case "$l" in *"repos/o/r/issues -f state=open -f labels=ai-build -F per_page=100 -F page=1"*) ok ;; *) bad "F5 [github-issues] no flag must ask state=open labels=ai-build as today: $l" ;; esac
case "$l" in *since=*) bad "F5 [github-issues] no flag sent a since: $l" ;; *) ok ;; esac
rm -f "$T/gs/reqs"; tracker_list --state all --label Ready --since 2026-10-21T00:00:00Z >/dev/null
l=$(head -1 "$T/gs/reqs")
case "$l" in *"-f state=all -f labels=Ready -f since=2026-10-21T00:00:00Z "*) ok ;; *) bad "F8 [github-issues] the flags must be the state, labels and since params: $l" ;; esac
[ "$(tracker_list | jq -c '[.[].id] | index("206")')" = null ] && ok || bad "F1 [github-issues] the list still drops the PR"

# ---- board ---------------------------------------------------------------------
jq -n '{tickets: [
  {id:"cmA", key:"XO-1", title:"Open new", status:"todo", labels:["ai-build"], lastActivityAt:"2026-10-21T00:00:00.000Z", commentCount:4},
  {id:"cmB", key:"XO-2", title:"Closed new", status:"Done", labels:["ai-build"], lastActivityAt:"2026-10-21T10:00:00.000Z", commentCount:1},
  {id:"cmC", key:"XO-3", title:"Other label", status:"todo", labels:[{name:"feature"}], lastActivityAt:"2026-10-21T10:00:00.000Z"},
  {id:"cmD", key:"XO-4", title:"One second early", status:"in_progress", labels:["ai-build"], updatedAt:"2026-10-20T23:59:59.000Z", commentCount:2},
  {id:"cmE", key:"XO-5", title:"No date", status:"review", labels:["ai-build"]}]}' > "$T/bs/list.json"
tc12_setup_board() {
  tracker_load board || return 1
  TRK_BOARD_BASE="https://board.example/api/board"; TRK_BOARD_TOKEN="$BTOK"; TRK_BOARD_TOKEN_VAR=XOS_INTERNAL_API_TOKEN
  TRK_LOG="$T/run/board.log"; TRK_ERR="$T/run/board.err"; TRK_DRY=0; TRK_REQ_FILE=""
  # cmA is updated EXACTLY at the cut (kept); cmD one second before it (dropped).
  C12_OPEN=cmA; C12_CLOSED=cmB; C12_OTHER=cmC; C12_OLD=cmD; C12_NODATE=cmE; C12_SINCE=2026-10-21T00:00:00Z
  C12_OPEN_UPDATED=2026-10-21T00:00:00Z; C12_OPEN_COMMENTS=4; C12_DROP_SINCE=""
}
c12_reqs()   { cat "$T/bs/reqs" 2>/dev/null | grep -c .; }
c12_writes() { cat "$T/bs/writes" 2>/dev/null; }
tracker_contract_c12 board   # F2
rm -f "$T/bs/reqs"; tracker_list >/dev/null
[ "$(cat "$T/bs/reqs")" = "GET https://board.example/api/board/boards
GET https://board.example/api/board/boards/b1/tickets" ] && ok || bad "F5 [board] no flag must ask the two routes of today: $(cat "$T/bs/reqs")"
[ "$(tracker_list | jq -c '[.[] | select(.id == "cmC") | .commentCount]')" = '[null]' ] && ok || bad "F2 [board] a row with no commentCount answers null, not 0"
[ ! -e "$T/bs/authbad" ] && ok || bad "F2 [board] a call without the token: $(cat "$T/bs/authbad")"

# ---- Jira ----------------------------------------------------------------------
jira_stub_setup "$T/j" || { echo "jira stub setup failed"; exit 1; }
tc12_setup_jira() {
  tracker_load jira || return 1
  TRK_LOG="$T/run/jira.log"; TRK_ERR="$T/run/jira.err"; TRK_DRY=0; TRK_REQ_FILE=""
  trk_jira_context jproj || return 1
  jq -n '{issues: [
    {key:"CROM-11", fields:{summary:"Open new", status:{name:"To Do", statusCategory:{key:"new"}}, labels:["ai-build"], updated:"2026-10-21T10:00:00.000+0300", comment:{comments:[], total:2, maxResults:0, startAt:0}}},
    {key:"CROM-12", fields:{summary:"Closed new", status:{name:"Done", statusCategory:{key:"done"}}, labels:["ai-build"], updated:"2026-10-21T10:00:00.000+0000", comment:{comments:[], total:0, maxResults:0, startAt:0}}},
    {key:"CROM-13", fields:{summary:"Other label", status:{name:"To Do", statusCategory:{key:"new"}}, labels:["feature"], updated:"2026-10-21T10:00:00.000+0000", comment:{comments:[], total:1, maxResults:0, startAt:0}}},
    {key:"CROM-14", fields:{summary:"Open old", status:{name:"In Progress", statusCategory:{key:"indeterminate"}}, labels:["ai-build"], updated:"2026-10-20T23:00:00.000+0000", comment:{comments:[], total:0, maxResults:0, startAt:0}}},
    {key:"CROM-15", fields:{summary:"No date", status:{name:"To Do", statusCategory:{key:"new"}}, labels:["ai-build"]}},
    {key:"CROM-16", fields:{summary:"Later in local time, earlier in UTC", status:{name:"To Do", statusCategory:{key:"new"}}, labels:["ai-build"], updated:"2026-10-21T02:00:00.000+0300"}}],
    isLast: true}' > "$JIRA_STUB_STATE/search-page1.json"
  C12_OPEN=CROM-11; C12_CLOSED=CROM-12; C12_OTHER=CROM-13; C12_OLD=CROM-14; C12_NODATE=CROM-15; C12_SINCE=2026-10-21T00:30:00Z
  C12_OPEN_UPDATED=2026-10-21T07:00:00Z; C12_OPEN_COMMENTS=2; C12_DROP_SINCE=CROM-16
}
c12_reqs()   { jira_req_count .; }
c12_writes() { cat "$JIRA_STUB_STATE/writes" 2>/dev/null; }
tracker_contract_c12 jira   # F3 (and F6 through C12_OPEN_UPDATED)
S="$JIRA_STUB_STATE"
lastjql() { local f; f=$(ls "$S"/search-req-*.json 2>/dev/null | sort -t- -k3 -n | tail -1); jq -r .jql "$f"; }
rm -f "$S"/search-req-*.json; tracker_list >/dev/null
[ "$(lastjql)" = 'project in ("CROM","CMNT") AND labels = "ai-build" AND statusCategory != Done ORDER BY updated DESC' ] \
  && ok || bad "F5 [jira] no flag must send the JQL of today: $(lastjql)"
# F6
[ "$(tracker_list | jq -r '.[] | select(.id == "CROM-11") | .updatedAt')" = 2026-10-21T07:00:00Z ] && ok || bad "F6 [jira] +0300 must print as UTC"
# F7
rm -f "$S"/search-req-*.json; out=$(tracker_list --since 2026-10-21T00:30:00Z)
case "$(lastjql)" in *'statusCategory != Done AND updated >= "2026-10-20" ORDER BY updated DESC') ok ;; *) bad "F7 [jira] --since must add the day before: $(lastjql)" ;; esac
printf '%s' "$out" | jq -e 'any(.[]; .id == "CROM-14") | not' >/dev/null && ok || bad "F7 [jira] a row updated 2026-10-20T23:00Z is before the cut and dropped"
rm -f "$S"/search-req-*.json; tracker_list --state all --label Ready >/dev/null
[ "$(lastjql)" = 'project in ("CROM","CMNT") AND labels = "Ready" ORDER BY updated DESC' ] && ok || bad "F7 [jira] --state all --label Ready: $(lastjql)"
jq -e '.fields | index("updated") != null and index("comment") != null' "$(ls "$S"/search-req-*.json | head -1)" >/dev/null \
  && ok || bad "F7 [jira] the list asks for the updated and comment fields"

# ---- Linear --------------------------------------------------------------------
linear_stub_setup "$T/l" "$DIR/tests/fixtures/triage-intake.bh-7920/linear" || { echo "linear stub setup failed"; exit 1; }
export LS_KEY_EXPECT="$LKEY"
mkdir -p "$T/l/h/env" "$T/l/h/state" "$T/l/h/logs"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$LKEY" > "$T/l/h/env/linproj.env"
lnode() { # lnode <id> <state type> <label> <updatedAt|null> <comment nodes> [hasNextPage]
  jq -nc --arg i "$1" --arg t "$2" --arg l "$3" --arg u "$4" --argjson n "$5" --argjson more "${6:-false}" \
    '{identifier:$i, title:("Issue " + $i), url:("https://linear.app/crosstest/issue/" + $i),
      updatedAt:(if $u == "null" then null else $u end), state:{name:$t, type:$t},
      labels:{nodes:[{name:$l}]}, comments:{nodes:[range($n) | {id:("c" + tostring)}], pageInfo:{hasNextPage:$more}}}'
}
{ lnode CRO-21 unstarted ai-build 2026-10-21T10:00:00.000Z 2
  lnode CRO-22 completed ai-build 2026-10-21T10:00:00.000Z 0
  lnode CRO-23 started feature 2026-10-21T10:00:00.000Z 0
  lnode CRO-24 unstarted ai-build 2026-10-20T00:00:00.000Z 1
  lnode CRO-25 backlog AI-Build null 0
  lnode CRO-26 canceled ai-build 2026-10-21T11:00:00.000Z 30 true
} | jq -s '{data:{issues:{nodes:., pageInfo:{hasNextPage:false, endCursor:null}}}}' > "$LS_STATE/issues.json"
tc12_setup_linear() {
  HARNESS="$T/l/h"
  tracker_load linear || return 1
  TRK_LOG="$T/run/linear.log"; TRK_ERR="$T/run/linear.err"; TRK_DRY=0; TRK_REQ_FILE=""
  trk_linear_context linproj || return 1
  C12_OPEN=CRO-21; C12_CLOSED=CRO-22; C12_OTHER=CRO-23; C12_OLD=CRO-24; C12_NODATE=CRO-25; C12_SINCE=2026-10-21T00:00:00Z
  C12_OPEN_UPDATED=2026-10-21T10:00:00Z; C12_OPEN_COMMENTS=2; C12_DROP_SINCE=""
}
c12_reqs()   { linear_req_count; }
c12_writes() { cat "$LS_STATE/reqs" 2>/dev/null | awk '$4 != "TrkIssues" && $4 != "TrkIssue"'; }
tracker_contract_c12 linear   # F4
q() { linear_req_of TrkIssues | jq -r "$1"; }
# F5
tracker_list >/dev/null
grep -qF 'state: { type: { nin: ["completed", "canceled"] } }' <<<"$(q .query)" && ok || bad "F5 [linear] no flag keeps the open filter: $(q .query)"
grep -qF 'team: { key: { eq: $team } }' <<<"$(q .query)" && ok || bad "F5 [linear] the team filter: $(q .query)"
grep -qF '$since' <<<"$(q .query)" && bad "F5 [linear] no flag must not name \$since: $(q .query)" || ok
[ "$(q '.variables | has("since")')" = false ] && [ "$(q .variables.label)" = ai-build ] && ok || bad "F5 [linear] the variables: $(q -c .variables)"
# F8
tracker_list --state all >/dev/null
grep -qF 'nin:' <<<"$(q .query)" && bad "F8 [linear] --state all must drop the nin part: $(q .query)" || ok
tracker_list --since 2026-10-21T00:00:00Z --label Ready >/dev/null
grep -qF '$since: DateTimeOrDuration' <<<"$(q .query)" && grep -qF 'updatedAt: { gte: $since }' <<<"$(q .query)" && ok || bad "F8 [linear] --since declares and uses \$since: $(q .query)"
[ "$(q '[.variables.since, .variables.label] | join(" ")')" = "2026-10-21T00:00:00Z Ready" ] && ok || bad "F8 [linear] --since and --label ride as variables: $(q -c .variables)"
# F9
[ "$(q .variables.cc)" = 25 ] && ok || bad "F9 [linear] no list_comment_cap row must send cc 25: $(q -c .variables)"
[ "$(tracker_list --state all | jq -c '[.[] | select(.id == "CRO-26") | .commentCount, .state]')" = '[null,"closed"]' ] \
  && ok || bad "F9 [linear] a comment page that has more answers commentCount null"
linear_set tracker_linear.linproj.list_comment_cap 10
trk_linear_context linproj && tracker_list >/dev/null
[ "$(q .variables.cc)" = 10 ] && ok || bad "F9 [linear] the row 10 must send cc 10: $(q -c .variables)"
for v in 0 99 ten; do
  linear_set tracker_linear.linproj.list_comment_cap "$v"
  n0=$(linear_req_count)
  trk_linear_context linproj 2>"$T/run/f9.err"; rc=$?
  [ "$rc" = 1 ] && [ -z "${TRK_LINEAR_TOKEN:-}" ] && ok || bad "F9 [linear] the row $v must fail the context (rc=$rc)"
  grep -q 'list_comment_cap' "$T/run/f9.err" && ok || bad "F9 [linear] the refusal names the row: $(cat "$T/run/f9.err")"
  out=$(TRK_LINEAR_TOKEN="$LKEY" TRK_LINEAR_TEAM=CRO TRK_LINEAR_LIST_COMMENT_CAP="$v" tracker_list 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && [ "$(linear_req_count)" = "$n0" ] && ok || bad "F9 [linear] a cap of $v must be rc 1 and send nothing (rc=$rc)"
done
linear_unset tracker_linear.linproj.list_comment_cap
[ ! -e "$LS_STATE/authbad" ] && ok || bad "F4 [linear] a call carried something other than the key"
LEAK=$(grep -rlF -- "$LKEY" "$T/run" "$LS_STATE" "$T/l/h/state" "$T/l/h/logs" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "F4 [linear] the key reached: $LEAK"

echo "tracker-list-filters.bh-7920: PASS $TC_PASS FAIL $TC_FAIL"
[ "$TC_FAIL" -eq 0 ]
