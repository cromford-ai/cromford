#!/bin/bash
# tests/tracker-create-search.bh-7922-test.sh — BH-7922 (wave 4 of #7916, slice
# C0): the new tracker_create form and tracker_search, through bin/lib/tracker.sh,
# against all four adapters with local stubs.
#
#   C13 x4   create: the normalized object + relationErrors, one create with
#            the footers once, a dry run writes nothing (tests/lib/tracker-contract-c13.bh-7922.sh)
#   C13c     Linear parentId = the parent's UUID and one issueRelationCreate
#            type blocks (blocker -> new); Jira fields.parent.key and one
#            issueLink Blocks; GitHub labels in the payload; the board's
#            idempotency key and its label refusal entry
#   C14 x4   search: the two title matches, the list row keys, the adapter's
#            own request (GitHub search/issues repo: in:title; board the list
#            GET; Jira JQL summary ~; Linear containsIgnoreCase)
#   A1-A7    the legacy <payload-json> <out> form vs the new form
#   G1-G2    a parent or blocker from another Jira project / Linear team is
#            rc 1 and sends nothing
#   J1       a Jira project with no parent field: no parent sent, one
#            relationErrors entry, the text footer still there
#   E1-E5    exit paths: 75 on the create, 2xx with no key, a failed
#            relation, a failed read-back
#   S1-S5    the query check, the title belt, the cap, a non-array answer
#   K1-K4    the knob trk_search.max_rows: a row, a bad row, read once,
#            a dry run reads no row
#   RT1-RT2  footer writer -> ticket-ref readers; create output == tracker_read
#   X1       no credential reaches a log or a state file
#
# No network: gh_rest is a recording fake defined before the adapter loads,
# and curl is a stub that plays the board, the Jira gateway, Linear's GraphQL
# API and the jobs-worker settings route. No stub writes argv or a header.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-create-search.bh-7922-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-contract-c13.bh-7922.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
ok()  { _c13_ok; }
bad() { TC_FAIL=$((TC_FAIL+1)); echo "FAIL $1"; }

BTOK=tok-fixture-board-7922
LKEY=lin-api-fixture-sentinel-7922
JTOK=tok-FIXTURE-SENTINEL-7922
JEMAIL=harness@example.com
JGW="https://api.atlassian.com/ex/jira/33333333-3333-3333-3333-333333333333"
ST="$T/st"
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$T/run" "$ST/gh" "$ST/board" "$ST/jira" "$ST/linear" "$ST/settings"
export HARNESS="$T/h" GH_ETAG=0 PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TS_ST="$ST" TS_BTOK="$BTOK" TS_LKEY="$LKEY" TS_JGW="$JGW"
TS_JAUTH="Basic $(printf '%s:%s' "$JEMAIL" "$JTOK" | base64 | tr -d '\n')"; export TS_JAUTH
export TRK_LINEAR_API=https://linear.example/graphql
printf 'JIRA_BASE=%s\nJIRA_EMAIL=%s\nJIRA_API_TOKEN=%s\nJIRA_SITE=https://sandbox-example.atlassian.net\n' "$JGW" "$JEMAIL" "$JTOK" > "$T/h/env/jproj.env"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$LKEY" > "$T/h/env/linproj.env"

setting() { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$ST/settings/setting-$1"; }
unsetting() { rm -f "$ST/settings/setting-$1"; }
settings_reads() { cat "$ST/settings/reads.log" 2>/dev/null | grep -c -x -- "$1"; }
setting tracker_jira.jproj.write_projects SCRUM
setting tracker_jira.jproj.read_projects "SCRUM DEPS"

# ---- the curl stub: board, Jira gateway, Linear API, settings ---------------
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TS_ST"; m=GET; url=""; data=""; out=""; fmt=""; auth=""; idem=""; failf=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -f) failf=1 ;;
    -sSf|-fsS) failf=1 ;;
    -m|--max-time|--connect-timeout|-u) shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; Idempotency-Key:*) idem="${2#Idempotency-Key: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
emit() { # emit <code> <body>
  if [ "$failf" = 1 ] && [ "$1" -ge 400 ]; then echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; fi
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  [ -n "$fmt" ] && printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
fx() { [ -r "$1" ] && cat "$1"; }
case "$url" in
  https://jobs.example/api/settings/*)
    key="${url##*/}"; echo "$key" >> "$S/settings/reads.log"
    f="$S/settings/setting-$key"
    [ -r "$f" ] && emit "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    emit 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) emit 404 '{}' ;;
  https://board.example/api/board/*)
    B="$S/board"; p="${url#https://board.example/api/board}"
    printf '%s %s\n' "$m" "$p" >> "$B/reqs"
    [ "$auth" = "Bearer $TS_BTOK" ] || echo "badauth $p" >> "$B/authbad"
    arm=$(cat "$B/arm" 2>/dev/null)
    case "$m $p" in
      "GET /boards") emit 200 '[{"id":"b1"}]' ;;
      "GET /boards/b1/tickets") emit 200 "$(fx "$B/list.json")" ;;
      "POST /boards/b1/tickets")
        echo "create" >> "$B/writes"; n=$(grep -c . "$B/writes"); cp "$data" "$B/create-$n.json"; echo "$idem" > "$B/idem-$n"
        cp "$data" "$B/created.json"
        [ "$arm" = create_500 ] && emit 500 '{"error":"down"}'
        [ "$arm" = create_nokey ] && emit 201 '{"ok":true}'
        emit 201 '{"ticket":{"id":"cmNEW77","key":"XO-77","url":"https://board.example/t/XO-77"}}' ;;
      "GET /tickets/cmNEW77")
        [ "$arm" = read_fail ] && emit 500 '{}'
        emit 200 "$(jq -c '{ticket:{id:"cmNEW77", key:"XO-77", title:.title, status:"todo", description:.description, labels:[], url:"https://board.example/t/XO-77"}, comments:[]}' "$B/created.json")" ;;
    esac
    [ "$m" = GET ] || echo "$m $p" >> "$B/writes"
    emit 404 '{"error":"not found"}' ;;
  "$TS_JGW"/*)
    J="$S/jira"; pq="${url#"$TS_JGW"}"; path="${pq%%\?*}"
    printf '%s %s\n' "$m" "$pq" >> "$J/reqs"
    [ "$auth" = "$TS_JAUTH" ] || { echo "badauth $m $path" >> "$J/authbad"; emit 401 '{}'; }
    arm=$(cat "$J/arm" 2>/dev/null)
    case "$m $path" in
      "GET /rest/api/3/issue/createmeta/SCRUM/issuetypes") emit 200 '{"issueTypes":[{"id":"10001","name":"Task"},{"id":"10002","name":"Bug"}]}' ;;
      "GET /rest/api/3/issue/createmeta/SCRUM/issuetypes/10001")
        [ "$arm" = noparent ] && emit 200 '{"fields":[{"fieldId":"summary"},{"fieldId":"labels"}]}'
        emit 200 '{"fields":[{"fieldId":"summary"},{"fieldId":"labels"},{"fieldId":"parent"}]}' ;;
      "POST /rest/api/3/issue")
        echo "create" >> "$J/writes"; n=$(grep -c '^create' "$J/writes"); cp "$data" "$J/create-$n.json"; cp "$data" "$J/created.json"
        [ "$arm" = create_429 ] && emit 429 '{"errorMessages":["Rate limit exceeded."]}'
        [ "$arm" = create_nokey ] && emit 201 '{"id":"10077"}'
        emit 201 '{"id":"10077","key":"SCRUM-77","self":"x"}' ;;
      "POST /rest/api/3/issueLink")
        echo "link" >> "$J/writes"; n=$(grep -c '^link' "$J/writes"); cp "$data" "$J/link-$n.json"
        [ "$arm" = link_fail ] && emit 404 '{"errorMessages":["No issue link type with name Blocks found."]}'
        emit 201 '' ;;
      "POST /rest/api/3/search/jql")
        cp "$data" "$J/search-req.json"; echo search >> "$J/searches"
        emit 200 "$(fx "$J/search.json")" ;;
      "GET /rest/api/3/issue/SCRUM-77/comment") emit 200 '{"startAt":0,"maxResults":100,"total":0,"comments":[]}' ;;
      "GET /rest/api/3/issue/SCRUM-77")
        [ "$arm" = read_fail ] && emit 503 '{}'
        emit 200 "$(jq -c '{key:"SCRUM-77", fields:{summary:.fields.summary, labels:(.fields.labels // []), project:{key:"SCRUM"},
                          status:{name:"To Do", statusCategory:{key:"new"}}, description:.fields.description}}' "$J/created.json")" ;;
      "GET /rest/api/3/issue/SCRUM-12"|"GET /rest/api/3/issue/SCRUM-13")
        k="${path##*/}"
        emit 200 "{\"key\":\"$k\",\"fields\":{\"project\":{\"key\":\"SCRUM\"},\"labels\":[],\"summary\":\"x\",\"status\":{\"name\":\"To Do\",\"statusCategory\":{\"key\":\"new\"}}}}" ;;
    esac
    [ "$m" = GET ] || echo "$m $path" >> "$J/writes"
    emit 404 '{"errorMessages":["no route"]}' ;;
  https://linear.example/graphql)
    L="$S/linear"
    op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
    echo "$op" >> "$L/reqs"; n=$(grep -c . "$L/reqs"); cp "$data" "$L/req-$n.json"
    [ "$auth" = "$TS_LKEY" ] || echo "badauth $op" >> "$L/authbad"
    arm=$(cat "$L/arm" 2>/dev/null)
    uuid() { printf 'lin-issue-%s' "${1#*-}"; }
    case "$op" in
      TrkTeam)
        emit 200 '{"data":{"teams":{"nodes":[{"id":"team-uuid-cro","labels":{"nodes":[{"id":"lab-ai","name":"ai-build"},{"id":"lab-bug","name":"Bug"}]}}]}}}' ;;
      TrkIssueMeta)
        id=$(jq -r '.variables.id' "$data")
        case "$id" in
          CRO-12|CRO-13|CRO-14) emit 200 "$(jq -nc --arg i "$id" --arg u "$(uuid "$id")" '{data:{issue:{id:$u, identifier:$i, state:{id:"s1"}, labels:{nodes:[]}, team:{key:"CRO", states:{nodes:[]}}}}}')" ;;
          CRO-15) emit 200 "$(jq -nc --arg u "$(uuid CRO-15)" '{data:{issue:{id:$u, identifier:"ABC-15", state:{id:"s1"}, labels:{nodes:[]}, team:{key:"ABC", states:{nodes:[]}}}}}')" ;;
        esac
        emit 200 '{"data":{"issue":null},"errors":[{"message":"Entity not found"}]}' ;;
      TrkCreate)
        echo "TrkCreate" >> "$L/writes"; cp "$data" "$L/created.json"
        [ "$arm" = create_429 ] && emit 429 '{"errors":[{"message":"rate limited","extensions":{"code":"RATELIMITED"}}]}'
        [ "$arm" = create_nokey ] && emit 200 '{"data":{"issueCreate":{"success":true,"issue":null}}}'
        emit 200 "$(jq -nc --arg u "$(uuid CRO-77)" '{data:{issueCreate:{success:true, issue:{id:$u, identifier:"CRO-77", url:"https://linear.app/x/issue/CRO-77"}}}}')" ;;
      TrkRelate)
        echo "TrkRelate" >> "$L/writes"
        [ "$arm" = relate_fail ] && emit 200 '{"data":null,"errors":[{"message":"Entity not found"}]}'
        emit 200 '{"data":{"issueRelationCreate":{"success":true}}}' ;;
      TrkIssue)
        id=$(jq -r '.variables.id' "$data")
        [ "$arm" = read_fail ] && emit 500 '{}'
        [ "$id" = CRO-77 ] && emit 200 "$(jq -c '.variables.input as $i | {data:{issue:{identifier:"CRO-77", title:$i.title, description:$i.description, url:"https://linear.app/x/issue/CRO-77",
              state:{name:"Todo", type:"unstarted"}, labels:{nodes:[($i.labelIds // [])[] | {name:(if . == "lab-ai" then "ai-build" else . end)}]},
              comments:{nodes:[], pageInfo:{hasNextPage:false}}}}}' "$L/created.json")"
        emit 200 '{"data":{"issue":null},"errors":[{"message":"Entity not found"}]}' ;;
      TrkSearch) emit 200 "$(fx "$L/search.json")" ;;
    esac
    echo "$op" >> "$L/writes"
    emit 400 '{"errors":[{"message":"unknown operation","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}' ;;
esac
echo "OFFBASE $m $url" >> "$S/offbase"
[ -n "$fmt" ] && printf '000'
exit 7
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$TS_ST/stray-gh"
exit 1
SH
chmod +x "$T/stub/curl" "$T/stub/gh"

# ---- the GitHub fake: gh_rest, before the adapter loads -----------------------
G="$ST/gh"; GH_ARM=""
# The two argument helpers bin/lib/gh-rest-list.sh calls, as bin/lib/gh-rest.sh defines them.
_gh_rest_args_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  if [ $# -ge 2 ]; then [[ "${2:-}" =~ ^[0-9]+$ ]] || return 1; fi
  return 0
}
_gh_rest_bad_args() { GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75; }
gh_rest() {
  local m="$1" p="$2" n f a q=""
  printf '%s\n' "$*" >> "$G/calls"
  GH_REST_STATUS=200; GH_REST_REASON=
  case "$m $p" in
    "POST repos/o/r/issues")
      echo create >> "$G/writes"
      f=""; for a in "$@"; do [ "$f" = next ] && f="$a"; [ "$a" = --input ] && f=next; done
      n=$(grep -c . "$G/writes"); cp "$f" "$G/create-$n.json"; cp "$f" "$G/created.json"
      case "$GH_ARM" in
        create_502) GH_REST_STATUS=502; return 75 ;;
        create_nonum) GH_REST_STATUS=201; printf '{"url":"x"}\n'; return 0 ;;
      esac
      GH_REST_STATUS=201
      printf '{"number":9077,"html_url":"https://github.com/o/r/issues/9077"}\n'; return 0 ;;
    "GET repos/o/r/issues/9077")
      [ "$GH_ARM" = read_fail ] && { GH_REST_STATUS=502; return 75; }
      jq -c '{number:9077, title, body, state:"open", labels:[(.labels // [])[] | {name:.}], html_url:"https://github.com/o/r/issues/9077"}' "$G/created.json"; return 0 ;;
    "GET repos/o/r/issues/9077/comments") printf '[]\n'; return 0 ;;
    "GET search/issues")
      for a in "$@"; do case "$a" in q=*) q="${a#q=}" ;; esac; done
      printf '%s\n' "$q" >> "$G/searches"
      [ "$GH_ARM" = search_429 ] && { GH_REST_STATUS=429; GH_REST_REASON=rate-limit; return 75; }
      cat "$G/search.json"; return 0 ;;
  esac
  [ "$m" = GET ] || echo "$m $p" >> "$G/writes"
  GH_REST_STATUS=404; return 44
}

. "$DIR/bin/lib/tracker.sh" || exit 1
TT="$T/run"
title() { printf '%s\n' "$1" > "$TT/title.txt"; printf '%s' "$TT/title.txt"; }

# ============================== GitHub ==========================================
reset_gh() { rm -f "$G"/calls "$G"/writes "$G"/create-*.json "$G"/searches; GH_ARM=""; }
tc13_setup_github_issues() {
  reset_gh; tracker_load github-issues || return 1
  TRK_SLUG=o/r; TRK_LOG="$TT/gh.log"; TRK_DRY=0; TRK_REQ_FILE=""
  C13_PARENT='#7916'; C13_BLOCKER='#7921'; C13_LABEL=ai-build
}
c13_writes()       { cat "$G/writes" 2>/dev/null; }
c13_creates()      { grep -c '^create' "$G/writes" 2>/dev/null; }
c13_create_title() { jq -r .title "$G/created.json"; }
c13_create_body()  { jq -r .body "$G/created.json"; }
tracker_contract_c13 github-issues
[ "$(jq -c .labels "$G/created.json")" = '["ai-build"]' ] && ok || bad "C13c [github-issues] the label rides in the payload: $(cat "$G/created.json")"
[ "$(printf '%s' "$C13_OUT" | jq -r '[.id, .key, .url] | join(" ")')" = "9077 #9077 https://github.com/o/r/issues/9077" ] \
  && ok || bad "C13 [github-issues] id 9077 key #9077 and the url: $C13_OUT"

jq -n '{total_count:4, items:[
  {number:301, title:"Fix revenue total", state:"open", labels:[{name:"ai-build"}], html_url:"https://github.com/o/r/issues/301", updated_at:"2026-11-01T00:00:00Z", comments:2},
  {number:302, title:"REVENUE report", state:"closed", labels:[], html_url:"https://github.com/o/r/issues/302", updated_at:"2026-11-02T00:00:00Z", comments:0},
  {number:303, title:"Totals page", body:"the revenue word is only here", state:"open", labels:[], updated_at:"2026-11-03T00:00:00Z", comments:0},
  {number:304, title:"Something else", state:"open", labels:[], updated_at:"2026-11-04T00:00:00Z", comments:1}]}' > "$G/search.json"
tc14_setup_github_issues() { reset_gh; tracker_load github-issues || return 1; TRK_SLUG=o/r; TRK_DRY=0; C14_MATCH="301 302"; }
c14_saw() { grep -qF 'repo:o/r is:issue in:title "revenue"' "$G/searches" 2>/dev/null; }
tracker_contract_c14 github-issues

# A1-A7: the legacy form vs the new form (on the GitHub adapter)
reset_gh
jq -n '{title:"x", body:"y"}' > "$TT/issue.json"; : > "$TT/created.json"
o=$(tracker_create "$TT/issue.json" "$TT/created.json"); rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && [ "$(jq -r .number "$TT/created.json")" = 9077 ] && ok || bad "A1 legacy: rc 0, nothing on stdout, GitHub's answer in <out> (rc=$rc out=$o)"
[ "$(cat "$G/calls")" = "POST repos/o/r/issues --input $TT/issue.json" ] && ok || bad "A1 legacy sends the payload file itself: $(cat "$G/calls")"
grep -qxF "gh api -X POST repos/o/r/issues --input $TT/issue.json" "$TT/gh.log" && ok || bad "A1 legacy logs its one line: $(cat "$TT/gh.log")"
reset_gh; rm -f "$TT/new-out.json"
o=$(tracker_create "$TT/issue.json" "$TT/new-out.json"); rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && [ -s "$TT/new-out.json" ] && ok || bad "A2 legacy with an <out> that does not exist yet (rc=$rc)"
reset_gh; printf 'Fix the thing\n' > "$TT/t.txt"; printf 'body\n' > "$TT/b.md"
o=$(tracker_create "$TT/t.txt" "$TT/b.md"); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -r '.title + "|" + (.relationErrors | tostring)')" = 'Fix the thing|[]' ] && ok || bad "A3 a title file is the new form (rc=$rc out=$o)"
reset_gh; printf '{not json\n' > "$TT/t2.txt"
o=$(tracker_create "$TT/t2.txt" "$TT/b.md"); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .title "$G/created.json")" = '{not json' ] && ok || bad "A4 '{not json' is the new form, title verbatim (rc=$rc)"
reset_gh; printf '[1,2]\n' > "$TT/t3.txt"
o=$(tracker_create "$TT/t3.txt" "$TT/b.md"); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .title "$G/created.json")" = '[1,2]' ] && ok || bad "A5 a JSON array is the new form (rc=$rc)"
reset_gh
o=$(tracker_create "$TT/issue.json" "$TT/b.md" --label x); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .title "$G/created.json")" = "$(head -1 "$TT/issue.json")" ] && ok || bad "A6 3+ args with a JSON object file is the new form, title = its first line (rc=$rc title=$(jq -r .title "$G/created.json" 2>/dev/null))"
reset_gh
e=$(tracker_create "$TT/no-such.txt" "$TT/b.md" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && grep -q 'title file' <<<"$e" && [ ! -s "$G/calls" ] && ok || bad "A7 an unreadable title file: rc 1, one line, nothing sent (rc=$rc err=$e)"

# argument refusals: rc 1, exactly one stderr line, nothing sent
reset_gh
refuse() {
  local e r
  e=$(tracker_create "$@" 2>&1 >/dev/null); r=$?
  [ "$r" = 1 ] && [ "$(printf '%s\n' "$e" | grep -c .)" = 1 ] && [ ! -s "$G/calls" ] && ok || bad "A8 tracker_create $* must be rc 1, one stderr line, nothing sent (rc=$r err=[$e])"
}
: > "$TT/empty.txt"; printf '%0300d\n' 0 > "$TT/long.txt"; printf 'a\tb\n' > "$TT/tab.txt"
refuse "$TT/t.txt"
refuse "$TT/t.txt" "$TT/no-body.md"
refuse "$TT/empty.txt" "$TT/b.md"
refuse "$TT/long.txt" "$TT/b.md"
refuse "$TT/tab.txt" "$TT/b.md"
refuse "$TT/t.txt" "$TT/b.md" --label 'a"b'
refuse "$TT/t.txt" "$TT/b.md" --label
refuse "$TT/t.txt" "$TT/b.md" --parent '#1' --parent '#2'
refuse "$TT/t.txt" "$TT/b.md" --blocked-by 'CRO 12'
refuse "$TT/t.txt" "$TT/b.md" --blocked-by cro-12
refuse "$TT/t.txt" "$TT/b.md" --frob x

# E2 75 on the create; E3 2xx with no number; E5 the read-back fails
reset_gh; GH_ARM=create_502
o=$(tracker_create "$TT/t.txt" "$TT/b.md" 2>/dev/null); rc=$?
[ "$rc" = 75 ] && [ -z "$o" ] && ok || bad "E2 [github-issues] a 502 on the create is rc 75, nothing printed (rc=$rc out=$o)"
reset_gh; GH_ARM=create_nonum
e=$(tracker_create "$TT/t.txt" "$TT/b.md" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && grep -q 'github-issues create answered HTTP 201 with no issue number; the ticket may exist' <<<"$e" && ok || bad "E3 [github-issues] a 2xx with no number is rc 1 and says the ticket may exist (rc=$rc err=$e)"
reset_gh; GH_ARM=read_fail
o=$(tracker_create "$TT/t.txt" "$TT/b.md" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c '[.id, .key, .readBack, .relationErrors]')" = '["9077","#9077",false,[]]' ] \
  && ok || bad "E5 [github-issues] a failed read-back is rc 0 with the minimal object and readBack false (rc=$rc out=$o)"
GH_ARM=""

# RT1: the footer writer and the ticket-ref readers
reset_gh
printf 'Body\nBlocked-by: CRO-13 (hard)\n' > "$TT/b2.md"
o=$(tracker_create "$TT/t.txt" "$TT/b2.md" --parent CRO-12 --blocked-by CRO-13 --blocked-by CRO-14 --blocked-by CRO-14); rc=$?
. "$DIR/bin/lib/ticket-ref.sh" || exit 1
body=$(jq -r .body "$G/created.json")
[ "$rc" = 0 ] && [ "$(ticket_ref_part_of <<<"$body")" = CRO-12 ] && ok || bad "RT1 Part of CRO-12 reads back (rc=$rc body=[$body])"
[ "$(ticket_ref_blocked_by <<<"$body" | tr '\n' ' ')" = 'CRO-13 CRO-14 ' ] && ok || bad "RT1 the blockers read back once each, no second CRO-13 line: [$body]"
printf 'Body\n\nPart of CRO-12\n' > "$TT/b3.md"; reset_gh
tracker_create "$TT/t.txt" "$TT/b3.md" --parent CRO-12 >/dev/null
[ "$(jq -r .body "$G/created.json")" = "$(cat "$TT/b3.md")" ] && ok || bad "RT1 a body that already holds the footer is sent unchanged: $(jq -r .body "$G/created.json")"
# RT2: the create's output equals a following tracker_read
reset_gh
o=$(tracker_create "$TT/t.txt" "$TT/b.md")
r=$(tracker_read "$(printf '%s' "$o" | jq -r .id)")
[ "$(printf '%s' "$o" | jq -c '{id,key,title,state}')" = "$(printf '%s' "$r" | jq -c '{id,key,title,state}')" ] \
  && ok || bad "RT2 [github-issues] create output == tracker_read: $o vs $r"

# S1-S5 and K1-K4 on the GitHub adapter
reset_gh; _TRK_SEARCH_MAX_CACHE=""
sref() {
  local o r n0
  n0=$(grep -c . "$G/calls" 2>/dev/null)
  o=$(tracker_search "$@" 2>/dev/null); r=$?
  [ "$r" = 1 ] && [ -z "$o" ] && [ "$(grep -c . "$G/calls" 2>/dev/null)" = "$n0" ] && ok || bad "S1 tracker_search $(printf '%q ' "$@") must be rc 1 with nothing sent (rc=$r out=$o)"
}
sref ""
sref "   "
sref "$(printf '%0201d' 0)"
sref "$(printf 'a\tb')"
sref revenue extra
sref
o=$(tracker_search "  ReVeNuE  "); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c '[.[].id] | sort')" = '["301","302"]' ] && ok || bad "S2 the belt matches case-insensitively, trimmed (rc=$rc out=$o)"
jq -n '{items:[{number:1, title:"rev enue"}, {number:2, title:null}, {number:3, body:"revenue"}, {number:4, title:"Revenue"}]}' > "$G/search.json.s3"
cp "$G/search.json" "$G/search.json.keep"; cp "$G/search.json.s3" "$G/search.json"
[ "$(tracker_search revenue | jq -c '[.[].id]')" = '["4"]' ] && ok || bad "S3 'rev enue', a null title and a body-only row are dropped: $(tracker_search revenue)"
jq -n '{items:[range(51) | {number:(1000 + .), title:"revenue \(.)"}]}' > "$G/search.json"
[ "$(tracker_search revenue | jq length)" = 50 ] && ok || bad "S4 51 matches with the cap 50 answer 50: $(tracker_search revenue | jq length)"
printf '{"items":"nope"}' > "$G/search.json"
o=$(tracker_search revenue 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$o" ] && ok || bad "S5 a non-array answer is rc 1 (rc=$rc out=$o)"
GH_ARM=search_429; o=$(tracker_search revenue 2>/dev/null); rc=$?; GH_ARM=""
[ "$rc" = 75 ] && ok || bad "S5 a rate-limited search is rc 75 (got $rc)"
jq -n '{items:[range(51) | {number:(1000 + .), title:"revenue \(.)"}]}' > "$G/search.json"
# K1: the row decides the cap; K3 it is read once per process
setting trk_search.max_rows 7; _TRK_SEARCH_MAX_CACHE=""; rm -f "$ST/settings/reads.log"
tracker_search revenue >/dev/null
[ "$(tracker_search revenue | jq length)" = 7 ] && ok || bad "K1 the row 7 caps the answer at 7: $(tracker_search revenue | jq length)"
tracker_search revenue >/dev/null
[ "$(settings_reads trk_search.max_rows)" = 1 ] && ok || bad "K3 the row is read once per process (read $(settings_reads trk_search.max_rows) times)"
# K2: a bad row takes the fallback 50, with one stderr line
for v in abc 0 101; do
  setting trk_search.max_rows "$v"; _TRK_SEARCH_MAX_CACHE=""
  e=$(tracker_search revenue 2>&1 >/dev/null); n=$(tracker_search revenue 2>/dev/null | jq length)
  [ "$n" = 50 ] && [ "$(printf '%s\n' "$e" | grep -c 'trk_search.max_rows')" = 1 ] && ok || bad "K2 the row $v takes the fallback 50 with one stderr line (n=$n err=[$e])"
done
# K4: a dry run reads no row
setting trk_search.max_rows 7; _TRK_SEARCH_MAX_CACHE=""; rm -f "$ST/settings/reads.log"
n=$(TRK_DRY=1 tracker_search revenue | jq length)
[ "$n" = 50 ] && [ "$(settings_reads trk_search.max_rows)" = 0 ] && ok || bad "K4 a dry run reads no row and takes 50 (n=$n reads=$(settings_reads trk_search.max_rows))"
unsetting trk_search.max_rows; _TRK_SEARCH_MAX_CACHE=""
n=$(tracker_search revenue | jq length)
[ "$n" = 50 ] && ok || bad "K1 no row takes the fallback 50 (n=$n)"
cp "$G/search.json.keep" "$G/search.json"

# ============================== board ===========================================
BS="$ST/board"
reset_board() { rm -f "$BS"/reqs "$BS"/writes "$BS"/create-*.json "$BS"/idem-* "$BS"/arm; }
tc13_setup_board() {
  reset_board; tracker_load board || return 1
  TRK_BOARD_BASE="https://board.example/api/board"; TRK_BOARD_TOKEN="$BTOK"; TRK_BOARD_TOKEN_VAR=XOS_INTERNAL_API_TOKEN
  TRK_LOG="$TT/board.log"; TRK_ERR="$TT/board.err"; TRK_DRY=0; TRK_REQ_FILE=""
  C13_PARENT=XO-12; C13_BLOCKER=XO-13; C13_LABEL=""
}
c13_writes()       { cat "$BS/writes" 2>/dev/null; }
c13_creates()      { grep -c '^create' "$BS/writes" 2>/dev/null; }
c13_create_title() { jq -r .title "$BS/created.json"; }
c13_create_body()  { jq -r .description "$BS/created.json"; }
tracker_contract_c13 board
[ "$(printf '%s' "$C13_OUT" | jq -r '[.id, .key] | join(" ")')" = "cmNEW77 XO-77" ] && ok || bad "C13 [board] id cmNEW77 key XO-77: $C13_OUT"
grep -q '^create-[0-9a-f]\{64\}$' "$BS/idem-1" && ok || bad "C13c [board] the create sends a content-hash idempotency key: $(cat "$BS/idem-1" 2>/dev/null)"
idem1=$(cat "$BS/idem-1")
reset_board; printf 'Fix the revenue total\n' > "$TT/bt.txt"; printf 'The revenue total double counts refunds.\n' > "$TT/bb.md"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --parent XO-12 --blocked-by XO-13 --label ai-build); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$BS/idem-1")" = "$idem1" ] && ok || bad "C13c [board] the same title and body send the same idempotency key (rc=$rc)"
[ "$(printf '%s' "$o" | jq -c .relationErrors)" = '["label ai-build: board has no labels"]' ] && ok || bad "C13c [board] --label is a relationErrors entry, the ticket is still created: $o"
reset_board; echo create_500 > "$BS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$o" ] && ok || bad "E2 [board] a failed create is rc 1, nothing printed (rc=$rc out=$o)"
reset_board; echo create_nokey > "$BS/arm"
e=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && grep -q 'the ticket may exist' <<<"$e" && ok || bad "E3 [board] a 2xx with no key is rc 1 and says so (rc=$rc err=$e)"
reset_board; echo read_fail > "$BS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c '[.id, .key, .readBack]')" = '["cmNEW77","XO-77",false]' ] && ok || bad "E5 [board] a failed read-back is rc 0 with readBack false (rc=$rc out=$o)"
reset_board

jq -n '{tickets:[
  {id:"cmA", key:"XO-1", title:"Fix revenue total", status:"todo", labels:["ai-build"], lastActivityAt:"2026-11-01T00:00:00.000Z", commentCount:1},
  {id:"cmB", key:"XO-2", title:"Revenue report", status:"Done", labels:[]},
  {id:"cmC", key:"XO-3", title:"Totals", description:"revenue only in the body", status:"todo", labels:[]},
  {id:"cmD", key:"XO-4", title:"Other", status:"todo", labels:[]}]}' > "$BS/list.json"
tc14_setup_board() { tc13_setup_board; C14_MATCH="cmA cmB"; }
c14_saw() { grep -qx 'GET /boards/b1/tickets' "$BS/reqs" 2>/dev/null; }
tracker_contract_c14 board
[ ! -e "$BS/authbad" ] && ok || bad "X1 [board] a call without the token: $(cat "$BS/authbad")"

# ============================== Jira ============================================
JS="$ST/jira"
reset_jira() { rm -f "$JS"/reqs "$JS"/writes "$JS"/create-*.json "$JS"/link-*.json "$JS"/arm "$JS"/searches; }
tc13_setup_jira() {
  reset_jira; tracker_load jira || return 1
  TRK_LOG="$TT/jira.log"; TRK_ERR="$TT/jira.err"; TRK_DRY=0; TRK_REQ_FILE=""
  trk_jira_context jproj || return 1
  C13_PARENT=SCRUM-12; C13_BLOCKER=SCRUM-13; C13_LABEL=ai-build
}
adf_text() { jq -r 'def t: if .type == "text" then .text elif .type == "hardBreak" then "\n" else ([.content[]? | t] | join("")) end;
                    [.fields.description.content[] | t] | join("\n\n")' "$1"; }
c13_writes()       { cat "$JS/writes" 2>/dev/null; }
c13_creates()      { grep -c '^create' "$JS/writes" 2>/dev/null; }
c13_create_title() { jq -r .fields.summary "$JS/created.json"; }
c13_create_body()  { adf_text "$JS/created.json"; }
tracker_contract_c13 jira
C="$JS/create-1.json"
[ "$(jq -c '[.fields.project.key, .fields.issuetype.id, .fields.parent.key, .fields.labels]' "$C")" = '["SCRUM","10001","SCRUM-12",["ai-build"]]' ] \
  && ok || bad "C13c [jira] the create names project SCRUM, type Task (10001), parent SCRUM-12, the label: $(jq -c .fields "$C")"
[ "$(grep -c '^link' "$JS/writes")" = 1 ] && [ "$(jq -c '[.type.name, .outwardIssue.key, .inwardIssue.key]' "$JS/link-1.json")" = '["Blocks","SCRUM-13","SCRUM-77"]' ] \
  && ok || bad "C13c [jira] one issueLink Blocks from SCRUM-13 to SCRUM-77: $(cat "$JS/link-1.json" 2>/dev/null)"
[ "$(printf '%s' "$C13_OUT" | jq -r .key)" = SCRUM-77 ] && ok || bad "C13 [jira] key SCRUM-77: $C13_OUT"
# G1: a foreign parent or blocker sends nothing at all
for args in "--parent OTHER-3" "--blocked-by OTHER-3" "--parent #12"; do
  reset_jira
  # shellcheck disable=SC2086 # the flag and its value, split on purpose
  o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" $args 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$o" ] && [ ! -s "$JS/reqs" ] && ok || bad "G1 [jira] $args is rc 1 with 0 requests (rc=$rc reqs=$(cat "$JS/reqs" 2>/dev/null))"
done
# a blocker in the read tier is linked; no write project at all refuses
reset_jira
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --blocked-by DEPS-4); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .outwardIssue.key "$JS/link-1.json" 2>/dev/null)" = DEPS-4 ] && ok || bad "G1 [jira] a read-tier blocker is linked (rc=$rc)"
# J1: a project with no parent field
reset_jira; echo noparent > "$JS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --parent SCRUM-12); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.fields | has("parent")' "$JS/create-1.json")" = false ] && ok || bad "J1 [jira] no parent field: the create sends no parent (rc=$rc)"
[ "$(printf '%s' "$o" | jq -c .relationErrors)" = '["parent SCRUM-12: project has no parent field (text footer only)"]' ] && ok || bad "J1 [jira] one relationErrors entry: $o"
adf_text "$JS/create-1.json" | grep -qx 'Part of SCRUM-12' && ok || bad "J1 [jira] the text footer still carries the parent"
# the issue type row
setting tracker_jira.jproj.issue_type Bug; reset_jira; trk_jira_context jproj
tracker_create "$TT/bt.txt" "$TT/bb.md" >/dev/null
[ "$(jq -r .fields.issuetype.id "$JS/create-1.json")" = 10002 ] && ok || bad "J2 [jira] the row tracker_jira.<p>.issue_type Bug picks type 10002"
unsetting tracker_jira.jproj.issue_type; trk_jira_context jproj
# E2 / E3 / E4 / E5
reset_jira; echo create_429 > "$JS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --blocked-by SCRUM-13 2>/dev/null); rc=$?
[ "$rc" = 75 ] && [ -z "$o" ] && [ "$(grep -c '^link' "$JS/writes")" = 0 ] && ok || bad "E2 [jira] a 429 on the create is rc 75, no link sent (rc=$rc)"
reset_jira; echo create_nokey > "$JS/arm"
e=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && grep -q 'the ticket may exist' <<<"$e" && ok || bad "E3 [jira] a 201 with no key is rc 1 and says so (rc=$rc err=$e)"
reset_jira; echo link_fail > "$JS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --blocked-by SCRUM-13 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -r '.key + " " + (.relationErrors | length | tostring) + " " + .relationErrors[0]')" = "SCRUM-77 1 blocked-by SCRUM-13: rc 1" ] \
  && ok || bad "E4 [jira] a failed link is rc 0 with one relationErrors entry (rc=$rc out=$o)"
reset_jira; echo read_fail > "$JS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c '[.key, .readBack]')" = '["SCRUM-77",false]' ] && ok || bad "E5 [jira] a failed read-back is rc 0, readBack false (rc=$rc out=$o)"
# RT2
reset_jira
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md"); r=$(tracker_read SCRUM-77)
[ "$(printf '%s' "$o" | jq -c '{id,key,title,state}')" = "$(printf '%s' "$r" | jq -c '{id,key,title,state}')" ] && ok || bad "RT2 [jira] create output == tracker_read: $o vs $r"

jq -n '{isLast:true, issues:[
  {key:"SCRUM-1", fields:{summary:"Fix revenue total", status:{name:"To Do", statusCategory:{key:"new"}}, labels:["ai-build"], updated:"2026-11-01T10:00:00.000+0000", comment:{total:1}}},
  {key:"SCRUM-2", fields:{summary:"Revenue reporting", status:{name:"Done", statusCategory:{key:"done"}}, labels:[]}},
  {key:"SCRUM-3", fields:{summary:"Totals (stemmed match)", status:{name:"To Do", statusCategory:{key:"new"}}, labels:[]}},
  {key:"SCRUM-4", fields:{summary:"Other", status:{name:"To Do", statusCategory:{key:"new"}}, labels:[]}}]}' > "$JS/search.json"
tc14_setup_jira() { tc13_setup_jira; C14_MATCH="SCRUM-1 SCRUM-2"; }
c14_saw() { [ "$(jq -r .jql "$JS/search-req.json")" = 'project in ("SCRUM","DEPS") AND summary ~ "revenue" ORDER BY updated DESC' ]; }
tracker_contract_c14 jira
[ "$(jq -r .maxResults "$JS/search-req.json")" = 50 ] && ok || bad "C14 [jira] maxResults is the cap 50: $(jq -c . "$JS/search-req.json")"
tracker_search 'say "hi" [x]' >/dev/null
[ "$(jq -r .jql "$JS/search-req.json")" = 'project in ("SCRUM","DEPS") AND summary ~ "say hi x" ORDER BY updated DESC' ] \
  && ok || bad "C14 [jira] quotes and Lucene characters never reach the JQL string: $(jq -r .jql "$JS/search-req.json")"
jq '.issues[0].key = "CLNT-1"' "$JS/search.json" > "$JS/search.json.n" && mv "$JS/search.json.n" "$JS/search.json"
o=$(tracker_search revenue 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$o" ] && ok || bad "C14 [jira] a row outside the readable projects fails the search (rc=$rc)"
[ ! -e "$JS/authbad" ] && ok || bad "X1 [jira] a call without the credential: $(cat "$JS/authbad")"

# ============================== Linear ==========================================
LS="$ST/linear"
reset_linear() { rm -f "$LS"/reqs "$LS"/writes "$LS"/req-*.json "$LS"/arm; }
tc13_setup_linear() {
  reset_linear; tracker_load linear || return 1
  TRK_LOG="$TT/linear.log"; TRK_ERR="$TT/linear.err"; TRK_DRY=0; TRK_REQ_FILE=""
  trk_linear_context linproj || return 1
  C13_PARENT=CRO-12; C13_BLOCKER=CRO-13; C13_LABEL=ai-build
}
lreq() { local n; n=$(grep -n -x "$1" "$LS/reqs" | tail -1 | cut -d: -f1); [ -n "$n" ] && cat "$LS/req-$n.json"; }
c13_writes()       { cat "$LS/writes" 2>/dev/null; }
c13_creates()      { grep -c '^TrkCreate' "$LS/writes" 2>/dev/null; }
c13_create_title() { jq -r .variables.input.title "$LS/created.json"; }
c13_create_body()  { jq -r .variables.input.description "$LS/created.json"; }
tracker_contract_c13 linear
[ "$(jq -c '.variables.input | [.teamId, .parentId, .labelIds]' "$LS/created.json")" = '["team-uuid-cro","lin-issue-12",["lab-ai"]]' ] \
  && ok || bad "C13c [linear] issueCreate: the team id, parentId = CRO-12's UUID, the label id: $(jq -c .variables.input "$LS/created.json")"
[ "$(grep -c '^TrkRelate' "$LS/writes")" = 1 ] && [ "$(lreq TrkRelate | jq -c '.variables.input | [.issueId, .relatedIssueId, .type]')" = '["lin-issue-13","lin-issue-77","blocks"]' ] \
  && ok || bad "C13c [linear] one issueRelationCreate type blocks, CRO-13 -> the new issue: $(lreq TrkRelate)"
[ "$(printf '%s' "$C13_OUT" | jq -r .key)" = CRO-77 ] && ok || bad "C13 [linear] key CRO-77: $C13_OUT"
grep -q 'linear graphql issueCreate ' "$TT/linear.log" && grep -q 'linear graphql issueRelationCreate ' "$TT/linear.log" && ok || bad "C13 [linear] both writes are logged: $(cat "$TT/linear.log")"
# G2: a parent or blocker on another team sends no write; a text refusal sends nothing at all
for args in "--parent ABC-3" "--blocked-by ABC-3" "--parent #12"; do
  reset_linear
  # shellcheck disable=SC2086 # the flag and its value, split on purpose
  o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" $args 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$o" ] && [ ! -s "$LS/reqs" ] && ok || bad "G2 [linear] $args is rc 1 with 0 requests (rc=$rc reqs=$(cat "$LS/reqs" 2>/dev/null))"
done
reset_linear
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --parent CRO-15 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ ! -s "$LS/writes" ] && ok || bad "G2 [linear] a CRO key Linear answers on team ABC (moved) is rc 1 with 0 writes (rc=$rc)"
# a label the team does not have: a relationErrors entry, the create goes
reset_linear
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --label nope --label BUG); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c .relationErrors)" = '["label nope: no such label on team CRO"]' ] \
  && [ "$(jq -c .variables.input.labelIds "$LS/created.json")" = '["lab-bug"]' ] && ok || bad "C13c [linear] an unknown label is one entry, a known one (any case) is sent (rc=$rc out=$o)"
# E2 / E3 / E4 / E5
reset_linear; echo create_429 > "$LS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --blocked-by CRO-13 2>/dev/null); rc=$?
[ "$rc" = 75 ] && [ -z "$o" ] && [ "$(grep -c TrkRelate "$LS/writes")" = 0 ] && ok || bad "E2 [linear] a rate-limited create is rc 75, no relation (rc=$rc)"
reset_linear; echo create_nokey > "$LS/arm"
e=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && grep -q 'the ticket may exist' <<<"$e" && ok || bad "E3 [linear] success with no identifier is rc 1 and says so (rc=$rc err=$e)"
reset_linear; echo relate_fail > "$LS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" --blocked-by CRO-13 --blocked-by CRO-14 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c .relationErrors)" = '["blocked-by CRO-13: rc 1","blocked-by CRO-14: rc 1"]' ] && ok || bad "E4 [linear] failed relations are rc 0 with one entry each (rc=$rc out=$o)"
reset_linear; echo read_fail > "$LS/arm"
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$o" | jq -c '[.key, .readBack]')" = '["CRO-77",false]' ] && ok || bad "E5 [linear] a failed read-back is rc 0, readBack false (rc=$rc out=$o)"
# RT2
reset_linear
o=$(tracker_create "$TT/bt.txt" "$TT/bb.md"); r=$(tracker_read CRO-77)
[ "$(printf '%s' "$o" | jq -c '{id,key,title,state}')" = "$(printf '%s' "$r" | jq -c '{id,key,title,state}')" ] && ok || bad "RT2 [linear] create output == tracker_read: $o vs $r"

lnode() { jq -nc --arg i "$1" --arg t "$2" '{identifier:$i, title:$t, url:("https://linear.app/x/issue/" + $i), updatedAt:"2026-11-01T00:00:00.000Z",
            state:{name:"Todo", type:"unstarted"}, labels:{nodes:[]}, comments:{nodes:[], pageInfo:{hasNextPage:false}}}'; }
{ lnode CRO-31 "Fix revenue total"; lnode CRO-32 "revenue REPORT"; lnode CRO-33 "Totals"; lnode CRO-34 "Other"; } \
  | jq -s '{data:{issues:{nodes:.}}}' > "$LS/search.json"
tc14_setup_linear() { tc13_setup_linear; C14_MATCH="CRO-31 CRO-32"; }
c14_saw() {
  lreq TrkSearch | jq -e '(.query | contains("title: { containsIgnoreCase: $q }") and contains("team: { key: { eq: $team } }"))
      and .variables.q == "revenue" and .variables.team == "CRO" and .variables.n == 50' >/dev/null 2>&1
}
tracker_contract_c14 linear
setting trk_search.max_rows 7; _TRK_SEARCH_MAX_CACHE=""
tracker_search revenue >/dev/null
[ "$(lreq TrkSearch | jq -r .variables.n)" = 7 ] && ok || bad "K1 [linear] the row 7 asks Linear for first 7"
unsetting trk_search.max_rows; _TRK_SEARCH_MAX_CACHE=""
[ ! -e "$LS/authbad" ] && ok || bad "X1 [linear] a call carried something other than the key"

# ============================== all =============================================
[ ! -e "$ST/offbase" ] && ok || bad "X1 a request left the stubs: $(cat "$ST/offbase")"
[ ! -e "$ST/stray-gh" ] && ok || bad "X1 the gh binary was called: $(cat "$ST/stray-gh")"
LEAK=$(grep -rlF -e "$LKEY" -e "$JTOK" -e "$BTOK" "$TT" "$ST" "$T/h/state" "$T/h/logs" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "X1 a credential reached: $LEAK"

echo "tracker-create-search.bh-7922: PASS $TC_PASS FAIL $TC_FAIL"
[ "$TC_FAIL" -eq 0 ]
