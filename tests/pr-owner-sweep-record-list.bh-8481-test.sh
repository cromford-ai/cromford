#!/bin/bash
# tests/pr-owner-sweep-record-list.bh-8481-test.sh — BH-8481 (C0):
# bin/pr-owner-sweep.sh reads its open and merged PR lists from the PR record
# (pr_records) instead of GitHub, and writes each GitHub list read back.
#
#   C1-C4  bin/lib/pr-record.sh, sourced, with a _jobs_req stub:
#     C1  pr_record_list with a window: the GET has order=created&limit=200,
#         and truncated:true is a hit
#     C2  without a window truncated:true is still the `truncated` miss
#     C3  pr_record_list_sync_gql on the GraphQL open fixture: app/x -> x[bot],
#         reviews keyed by the bare login, no mergeable_state key, and the body
#         is the worker suite's RT fixture (one shared fixture pair)
#     C4  the merged body: merged_at and pr_created_at on every row; RT fixture
#   P1-P9  the REAL bin/pr-owner-sweep.sh, whole, in its own scratch tree per
#     case, against a gh PATH shim that logs every call and answers only what
#     the case's fixture files hold, and a file-backed jobs worker behind a
#     curl shim. The curl shim answers GET /api/pr-records?...state=<s> with
#     $W/list-<s>.json (the list answer shape of the route, see
#     worker/jobs/test/pr-record-reviews.bh-8481.test.js; no file = no sync)
#     and saves each POST /api/pr-record-lists body as $H/post-<state>.json.
#     prs_wake_seen is an exported table double (the BH-8270 suite's).
#     P1  run A reads GitHub (2 list calls, 1 PRR_MISS) and posts both lists;
#         run B on a record built from run A's posts makes 0 list calls, 0
#         PRR_MISS, 1 PRR_HIT, with the same verdicts and the same dup-guard
#         line (it reads latestReviews from the record's reviews)
#     P2  merged no-sync with open fresh -> GitHub, 1 PRR_MISS
#     P3  the floor: age 3600 hits; 3601, knob 0 and no meta read GitHub
#     P4  missing:reviews, missing:created_at -> GitHub
#     P5  unknown:1, a `pr` wake since the stamp, WAKE_BACKSTOP=0 -> GitHub
#     P6  PR_RECORD_MAX_AGE_S=0 -> 0 GET /api/pr-records
#     P7  the conflict clock: an unknown mergeable with a due clock and no
#         label -> GitHub (miss=conflict); with the label -> record; not due ->
#         record, and the new state file keeps dirty_since; a due clock that
#         reaches the classifier only through the D1 owner rows labels nothing
#     P8  PR_OWNER_DRY_RUN=1 -> GitHub read, 0 POST /api/pr-record-lists
#     P9  an open page of exactly PR_LIMIT rows -> no open sync; merged posts
#     B1  no call left the fixture
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-record-list.bh-8481-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=1790000000                      # pinned: PR_OWNER_NOW and WAKE_BACKSTOP_NOW
OLD=2026-09-01T00:00:00Z            # every PR moved long before the grace window
S=example-org/fx; P=fx
GQ="$DIR/tests/fixtures/bh-8481"
FX="$DIR/worker/jobs/test/fixtures"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf "$1%.0s" $(seq 40); }
HA=$(sha a); HB=$(sha b)

# ============================================================================
# C. the client, sourced
# ============================================================================
CF="$T/c"; mkdir -p "$CF"
# C <answer-json> -- <fn> <args...>: one call in a subshell; the stub logs each
# request to $CF/reqs, saves a POST body to $CF/body and answers $CF/answer.
C() {
  printf '%s' "$1" > "$CF/answer"; shift 2
  : > "$CF/reqs"; rm -f "$CF/body"
  ( unset HARNESS H
    _jobs_req() { printf '%s %s\n' "$1" "$2" >> "$CF/reqs"; [ -z "${3:-}" ] || printf '%s' "$3" > "$CF/body"; cat "$CF/answer"; }
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    "$@" > "$CF/out" ); CRC=$?
  COUT=$(cat "$CF/out")
}
LANS() { # LANS <truncated> <age_s>: a list answer with one row and a sync stamp
  jq -nc --argjson tr "$1" --argjson a "$2" '{rows:[{number:1,title:"t",reviews:{}}], truncated:$tr, missing:null, unknown:0,
    sync:{synced_at:"2026-10-26T11:59:00Z", age_s:$a, rows:1}}'
}
C "$(LANS true 60)" -- pr_record_list "$S" merged "$CF/l.json" title,merged_at 200
eq "C1 rc" "$CRC" 0
eq "C1 the GET" "$(cat "$CF/reqs")" "GET /api/pr-records?repo=example-org/fx&state=merged&need=title,merged_at&order=created&limit=200"
eq "C1 the rows" "$(jq -c '.[0].number' "$CF/l.json")" 1
C "$(LANS true 60)" -- pr_record_list "$S" merged "$CF/l.json" - 200
eq "C1 need - is no need" "$(cat "$CF/reqs")" "GET /api/pr-records?repo=example-org/fx&state=merged&order=created&limit=200"
C "$(LANS true 60)" -- pr_record_list "$S" merged "$CF/l.json" title
eq "C2 no window: truncated is a miss" "$CRC:$COUT" "1:truncated"
eq "C2 the GET has no window" "$(cat "$CF/reqs")" "GET /api/pr-records?repo=example-org/fx&state=merged&need=title"
for w in 0 5001 abc; do
  C "$(LANS false 60)" -- pr_record_list "$S" merged "$CF/l.json" title "$w"
  eq "C2 window '$w' is rc 2 with no request" "$CRC:$(grep -c . "$CF/reqs")" "2:0"
done

C '{"synced_at":"2026-10-26T11:30:00Z","written":3,"absent":0}' -- pr_record_list_sync_gql "$S" open "$GQ/gql-open.json" 2026-10-26T11:30:00Z
eq "C3 rc" "$CRC" 0
eq "C3 one POST" "$(cat "$CF/reqs")" "POST /api/pr-record-lists"
eq "C3 app/dependabot -> dependabot[bot]" "$(jq -r '.rows[] | select(.number == 203) | .fields.author' "$CF/body")" "dependabot[bot]"
eq "C3 app/cromford -> cromford[bot]" "$(jq -r '.rows[] | select(.number == 201) | .fields.author' "$CF/body")" "cromford[bot]"
eq "C3 reviews keyed by the bare login" "$(jq -c '.rows[] | select(.number == 201) | .fields.reviews | keys' "$CF/body")" '["cromford","operator"]'
eq "C3 the state, commit and time" "$(jq -r '.rows[] | select(.number == 201) | .fields.reviews.operator | "\(.state) \(.commit_id) \(.at)"' "$CF/body")" "COMMENTED null 2026-10-26T08:10:00Z"
eq "C3 an empty latestReviews is reviews {}" "$(jq -c '.rows[] | select(.number == 202) | .fields.reviews' "$CF/body")" '{}'
eq "C3 no mergeable_state key" "$(jq '[.rows[].fields | has("mergeable_state")] | any' "$CF/body")" false
eq "C3 body null -> \"\"" "$(jq -c '.rows[] | select(.number == 202) | .fields.body' "$CF/body")" '""'
# The writer side of the RT round trip: the rows it posts are the rows the
# worker suite posts to the real route (one shared fixture pair).
rows_of() { jq -c '[.rows | sort_by(.number)[] | {number, fields: (.fields | to_entries | sort_by(.key) | from_entries)}]' "$1"; }
eq "C3 the rows are the worker suite RT fixture's" "$(rows_of "$CF/body")" "$(rows_of "$FX/bh-8481-sync-open-body.json")"
eq "C3 repo, state, at" "$(jq -r '"\(.repo) \(.state) \(.at)"' "$CF/body")" "$(jq -r '"\(.repo) \(.state) \(.at)"' "$FX/bh-8481-sync-open-body.json")"
NOREV=$(jq -c 'map(del(.latestReviews))' "$GQ/gql-open.json"); printf '%s' "$NOREV" > "$CF/norev.json"
C '{"synced_at":"2026-10-26T11:30:00Z"}' -- pr_record_list_sync_gql "$S" open "$CF/norev.json"
eq "C3 a page without latestReviews writes no reviews key" "$(jq '[.rows[].fields | has("reviews")] | any' "$CF/body")" false
eq "C3 no at: the worker's clock" "$(jq 'has("at")' "$CF/body")" false

C '{"synced_at":"2026-10-26T11:30:00Z"}' -- pr_record_list_sync_gql "$S" merged "$GQ/gql-merged.json" 2026-10-26T11:30:00Z
eq "C4 rc" "$CRC" 0
eq "C4 merged_at and pr_created_at on every row" "$(jq '[.rows[].fields | (.merged_at | type) == "string" and (.pr_created_at | type) == "string" and .state == "merged"] | all' "$CF/body")" true
eq "C4 the rows are the worker suite RT fixture's" "$(rows_of "$CF/body")" "$(rows_of "$FX/bh-8481-sync-merged-body.json")"
C '{"error":"invalid_field"}' -- pr_record_list_sync_gql "$S" merged "$GQ/gql-merged.json"
eq "C4 an answer with no synced_at is rc 1" "$CRC" 1
C '{"synced_at":"x"}' -- pr_record_list_sync_gql "$S" closed "$GQ/gql-merged.json"
eq "C4 closed is rc 1 with no request" "$CRC:$(grep -c . "$CF/reqs")" "1:0"

# ============================================================================
# The driven sweep: one template, one fresh copy per case (the BH-8270 harness)
# ============================================================================
TPL="$T/tpl"
mkdir -p "$TPL/bin" "$TPL/logs" "$TPL/locks" "$TPL/flags" "$TPL/state" "$TPL/env" "$TPL/fx" "$TPL/w" "$T/fakebin"
ln -sf "$DIR/bin/fleet-conf.sh" "$TPL/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf '%s %s https://fx.example - 2 box-fx\n' "$P" "$S" > "$TPL/fleet.conf"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$TPL/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.log"\nexit 0\n' > "$TPL/bin/lane-alert.sh"
printf '#!/bin/bash\necho "MC_ONLY_PR=${MC_ONLY_PR:-}" >> "$HARNESS/spawns.log"\n' > "$TPL/bin/merge-conductor.sh"
printf '#!/bin/bash\necho local\n' > "$TPL/bin/box-for.sh"
chmod +x "$TPL/bin/lane-alert.sh" "$TPL/bin/merge-conductor.sh" "$TPL/bin/box-for.sh"
for s in bin/pr-owner-sweep.sh bin/merge-conductor-backstop.sh bin/jobs-client.sh bin/alert-line.sh bin/lib/hub-box.sh; do
  scratch_install_closure "$s" "$TPL" >/dev/null || { echo "closure install failed: $s"; exit 1; }
done
[ -r "$TPL/bin/lib/pr-record.sh" ] || { echo "FAIL: the sweep's closure has no bin/lib/pr-record.sh"; FAIL=$((FAIL+1)); }
touch "$TPL/flags/pr-state-rows"
export GH_TOKEN=tok-fixture-1 GH_BUDGET_TTL_S=0 GH_ETAG=0 PR_OWNER_NOW="$NOW" BOX_NAME=box-hub HUB_BOX_NAME=box-hub JOBS_RETRIES=0 JOBS_ALERT=0

# gh: answers only what $H/fx holds; a missing fixture is a failed call.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
FX="$HARNESS/fx"
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":2000000000},"graphql":{"remaining":4000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api repos/"*" -q .id") echo 1234; exit 0 ;;
  *"pr list -R "*"--state open"*)   [ -f "$FX/open.json" ] || exit 1; cat "$FX/open.json"; exit 0 ;;
  *"pr list -R "*"--state merged"*) [ -f "$FX/merged.json" ] || exit 1; cat "$FX/merged.json"; exit 0 ;;
  *"api -i -X POST repos/"*|*"api -i -X PATCH repos/"*) restpr --raw 200 '{}'; exit 0 ;;
  *"api -i -X GET repos/"*"/compare/"*) restpr --raw 200 '{"status":"diverged"}'; exit 0 ;;
  *"api -i -X GET repos/"*"/issues/"*"/events"*|*"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]'; exit 0 ;;
esac
exit 1
SH
# the jobs worker: reads logged to reads.log, writes to writes.log. Any URL
# that is not the fixture worker is logged to escapes.log and fails.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
W="$HARNESS/w"; URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
case "$URL" in https://jobs.test/*) ;; *) printf '%s %s\n' "$M" "$URL" >> "$HARNESS/escapes.log"; exit 7 ;; esac
P="${URL#https://jobs.test}"
ans() { printf '%s\n%s\n' "$2" "$1"; exit 0; }
dec() { printf '%b' "${1//%/\\x}"; }
if [ "$M" != GET ]; then
  printf 'JOBS %s %s\n' "$M" "${P%%\?*}" >> "$HARNESS/writes.log"
  case "$P" in
    /api/pr-record-lists)
      st=$(jq -r .state <<<"$BODY"); printf '%s\n' "$BODY" > "$HARNESS/post-$st.json"
      ans 200 "$(jq -c '{written: (.rows | length), absent: 0, synced_at: (.at // "2026-09-21T14:13:20Z")}' <<<"$BODY")" ;;
    /api/pr-owners*) ans 200 '{"ok":true,"as_of":"2026-09-21T14:13:20Z"}' ;;
  esac
  ans 200 '{"ok":true}'
fi
printf 'JOBS GET %s\n' "$(dec "$P")" >> "$HARNESS/reads.log"
case "$P" in
  /api/pr-records\?*number=*) ans 200 '{"row":null}' ;;
  /api/pr-records\?*) q=$(dec "${P#*\?}"); st=$(sed -nE 's/.*state=([a-z]+).*/\1/p' <<<"$q")
    [ -f "$W/list-$st.json" ] && ans 200 "$(cat "$W/list-$st.json")"
    ans 200 '{"rows":[],"truncated":false,"missing":null,"unknown":0,"sync":null}' ;;
  /api/pr-owners\?*) [ -f "$W/owners.json" ] && ans 200 "$(cat "$W/owners.json")"; ans 200 '{"pr_owners":[]}' ;;
  /api/pr-state\?*) ans 404 '{"error":"no rows"}' ;;
  /api/verdicts\?*) ans 200 '{"standing":null}' ;;
  /api/jobs*) ans 200 '{"jobs":[]}' ;;
  /api/queue*) ans 200 '{"queue":[]}' ;;
esac
ans 404 '{"error":"no rows"}'
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

prs_wake_seen() {
  local r
  [ -f "$HARNESS/wake" ] || return 2
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*" || key == "-") { print $3; exit }' "$HARNESS/wake")
  return "${r:-1}"
}
export -f prs_wake_seen

fresh() {
  H="$T/c-$1"; W="$H/w"
  cp -a "$TPL" "$H" || { echo "setup: could not copy the template for $1"; exit 1; }
  export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
  printf '* * 1\n' > "$H/wake"
  CD="$H/state/pr-owner-sweep/example-org_fx"
}
# opr <num> <head-ref> [author] [mergeable] [labels-csv] [body] [reviews-json]: one open PR on the GitHub list fixture
opr() {
  local f="$H/fx/open.json"; [ -s "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg r "$2" --arg a "${3:-operator}" --arg m "${4:-MERGEABLE}" --arg l "${5:-}" --arg b "${6:-}" \
     --argjson rv "${7:-[]}" --arg h "$HA" --arg s "$S" --arg t "$OLD" \
    '. + [{number:$n,title:"scratch tool",headRefName:$r,headRefOid:$h,baseRefName:"main",author:{login:$a},
           labels:[$l | split(",")[] | select(. != "") | {name:.}],body:$b,mergeable:$m,updatedAt:$t,createdAt:$t,
           url:("https://github.com/"+$s+"/pull/"+($n|tostring)),isDraft:false,latestReviews:$rv}]' "$f" > "$f.t" && mv "$f.t" "$f"
  [ -s "$H/fx/merged.json" ] || echo '[]' > "$H/fx/merged.json"
}
mpr() { # mpr <num> <head-ref> <mergedAt>: one merged PR
  local f="$H/fx/merged.json"; [ -s "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg r "$2" --arg m "$3" --arg s "$S" --arg t "$OLD" \
    '. + [{number:$n,title:"merged",headRefName:$r,url:("https://github.com/"+$s+"/pull/"+($n|tostring)),mergedAt:$m,author:{login:"operator"},createdAt:$t}]' \
    "$f" > "$f.t" && mv "$f.t" "$f"
}
nogh() { rm -f "$H/fx/open.json" "$H/fx/merged.json"; }
# rec_lists <at> [ms-csv]: the record's two list answers, built from the
# fixture through the REAL writer (pr_record_list_sync_gql's body) the way the
# route stores it: stamp 60 s before <at>, newest created first. ms-csv maps
# numbers to a mergeable_state (`306=dirty,...`), as the pull_request webhook
# stores it (`306=` is NULL, as after a base push); the GraphQL sync never
# writes one, so every other row is clean.
rec_lists() {
  local at="$1" ms="${2:-}" st fx="$H/fx"
  for st in open merged; do
    ( unset HARNESS H; _jobs_req() { printf '%s' "$3" > "$W/body-$st.json"; echo '{"synced_at":"x"}'; }
      . "$DIR/bin/lib/pr-record.sh" && pr_record_list_sync_gql "$S" "$st" "$fx/$st.json" ) >/dev/null || { echo "setup: rec_lists $st"; exit 1; }
    rec_from_post "$W/body-$st.json" "$at" "$ms" > "$W/list-$st.json"
  done
}
rec_from_post() { # <post-body> <at> [ms-csv] -> a list answer
  jq -c --arg sa "$(iso $(($2 - 60)))" --arg ms "${3:-}" '
    ($ms | split(",") | map(select(. != "") | split("=") | {key: .[0], value: .[1]}) | from_entries) as $m
    | {rows: ([.rows[] | .fields as $f | (.number | tostring) as $k | {number, title: $f.title, head_ref: $f.head_ref, head_sha: $f.head_sha, base_ref: $f.base_ref,
          author: $f.author, labels: $f.labels, body: $f.body,
          mergeable_state: (if $f.state != "open" then null
                            elif ($m | has($k)) then ($m[$k] | if . == "" then null else . end)
                            else "clean" end),
          updated_at: $f.pr_updated_at, created_at: $f.pr_created_at, url: $f.url,
          draft: (if $f.draft == true then 1 elif $f.draft == false then 0 else null end),
          merged_at: $f.merged_at, reviews: $f.reviews}]
          | sort_by(.created_at, .number) | reverse),
       truncated: false, missing: null, unknown: 0, sync: {synced_at: $sa, age_s: 60, rows: (.rows | length)}}' "$1"
}
meta() { # meta <epoch>: the copy's two halves, stamped <epoch>, from the GitHub fixture
  mkdir -p "$CD"
  cp "$H/fx/open.json" "$CD/openlist.json"; printf -- '-\t%s\n' "$1" > "$CD/openlist.meta"
  cp "$H/fx/merged.json" "$CD/mergedlist.json"; printf -- '-\t%s\n' "$1" > "$CD/mergedlist.meta"
}
run() { # run <at> [VAR=val...]: one fleet-wide --explain sweep; each run starts its own logs
  local at="$1"; shift
  for f in gh-calls.log reads.log writes.log; do rm -f "$H/$f"; done
  rm -f "$H"/post-*.json
  : > "$H/logs/pr-owner-sweep.log"; : > "$H/logs/pr-record.log"
  OUT=$(env HARNESS_TEST_SANDBOX=1 WAKE_BACKSTOP_NOW="$at" "$@" "$H/bin/pr-owner-sweep.sh" --explain "$P" 2>/dev/null)
  LOGS=$(cat "$H/logs/pr-owner-sweep.log" 2>/dev/null)
  RLOG=$(cat "$H/logs/pr-record.log" 2>/dev/null)
}
prcalls() { grep -vE '^api rate_limit|^api repos/[^ ]+ -q \.id$' "$H/gh-calls.log" 2>/dev/null; }
listcalls() { prcalls | grep -c 'pr list -R'; }
misses() { grep -c " PRR_MISS $S#list " <<<"$LOGS"; }
hits() { grep -c " PRR_HIT $S#list src=record\$" <<<"$LOGS"; }
verdicts() { awk 'f; /^# example-org\/fx$/ {f=1}' <<<"$OUT"; }
posts() { find "$H" -maxdepth 1 -name 'post-*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' '; }
listgets() { grep -c 'GET /api/pr-records?.*state=' "$H/reads.log" 2>/dev/null; }
recmiss() { grep -c "list example-org/fx $1" <<<"$RLOG"; }
github() { # github <name> <why-word>: the run read GitHub once for both lists, with one PRR_MISS
  [ "$(listcalls)" = 2 ] && [ "$(misses)" = 1 ] && [ "$(hits)" = 0 ] && ok \
    || bad "$1 wanted 2 list reads, 1 PRR_MISS, no hit: $(prcalls) / $(grep -E 'PRR_(MISS|HIT)' <<<"$LOGS")"
  [ "$(recmiss "$2")" = 1 ] && ok || bad "$1 wanted one pr-record.log line '$2': $RLOG"
}
record() { # record <name>: the run used the record, no GitHub list read, no PRR_MISS
  [ "$(listcalls)" = 0 ] && [ "$(misses)" = 0 ] && [ "$(hits)" = 1 ] && ok \
    || bad "$1 wanted 0 list reads, 0 PRR_MISS, 1 PRR_HIT: $(prcalls) / $(grep -E 'PRR_(MISS|HIT)' <<<"$LOGS") / $RLOG"
}

# The P1 board. #301 ORPHAN, superseded: its key merged in #290 after it opened,
# and it carries an APPROVE (dup-guard keeps it); #302 PARKED; #303 EXTERNAL;
# #304/#305 two open PRs of one key; #306 ORPHAN CONFLICTING since OLD.
APPROVED='[{"author":{"login":"app/cromford"},"state":"APPROVED","submittedAt":"2026-09-02T00:00:00Z","commit":{"oid":"'"$HA"'"}}]'
board() {
  opr 301 ticket/bh-301 operator MERGEABLE "" "" "$APPROVED"
  opr 302 ticket/bh-302 operator MERGEABLE parked
  opr 303 feature/contrib someone-else
  opr 304 ticket/bh-304 operator
  opr 305 ticket/bh-304-r2 operator MERGEABLE "" "" '[{"author":{"login":"operator"},"state":"COMMENTED","submittedAt":"2026-09-02T00:00:00Z","commit":null}]'
  opr 306 ticket/bh-306 operator CONFLICTING
  mpr 290 ticket/bh-301 2026-09-10T00:00:00Z
  mpr 280 ticket/bh-280 2026-08-10T00:00:00Z
}

# ── P1: run A on GitHub, run B on the record it wrote: same verdicts ──────────
fresh p1; board
run "$NOW"
VA=$(verdicts); GA=$(grep -oE "$S#301: duplicate close refused — [a-z-]+" <<<"$LOGS")
[ "$(listcalls)" = 2 ] && [ "$(misses)" = 1 ] && [ "$(hits)" = 0 ] && ok || bad "P1 run A wanted 2 list reads and 1 PRR_MISS: $(prcalls) / $LOGS"
eq "P1 run A posted both lists" "$(posts)" "post-merged.json post-open.json "
eq "P1 run A open sync at the read's start" "$(jq -r '.at' "$H/post-open.json" 2>/dev/null)" "$(iso "$NOW")"
eq "P1 run A merged sync carries createdAt" "$(jq -c '[.rows[].fields.pr_created_at] | unique' "$H/post-merged.json" 2>/dev/null)" "[\"$OLD\"]"
grep -q $'^301\tORPHAN\tclose-duplicate:290' <<<"$VA" && grep -q $'^302\tPARKED' <<<"$VA" && grep -q $'^303\tEXTERNAL' <<<"$VA" \
  && grep -q $'^306\tORPHAN\tstale-conflict:' <<<"$VA" && ok || bad "P1 run A verdicts are not the fixture's: $VA"
eq "P1 run A dup-guard keeps #301 on its APPROVE" "$GA" "$S#301: duplicate close refused — approved"
# Run B, the next tick: the copy is older than PR_RECORD_MAX_AGE_S, the
# record holds what run A posted, and GitHub answers no list at all.
cp "$H/post-open.json" "$W/body-open.json"; cp "$H/post-merged.json" "$W/body-merged.json"
rec_from_post "$W/body-open.json" $((NOW + 1000)) 306=dirty > "$W/list-open.json"
rec_from_post "$W/body-merged.json" $((NOW + 1000)) > "$W/list-merged.json"
nogh
run $((NOW + 1000))
record "P1 run B"
eq "P1 run B verdicts equal run A" "$(verdicts)" "$VA"
eq "P1 run B dup-guard line equals run A (latestReviews from the record)" "$(grep -oE "$S#301: duplicate close refused — [a-z-]+" <<<"$LOGS")" "$GA"
eq "P1 run B posts nothing" "$(posts)" ""
grep -q 'GET /api/pr-records?repo=example-org/fx&state=open&need=title,head_ref,head_sha,base_ref,author,labels,body,url,created_at,updated_at,reviews,draft&order=created&limit=200' "$H/reads.log" \
  && grep -q 'GET /api/pr-records?repo=example-org/fx&state=merged&need=title,head_ref,url,merged_at,author,created_at&order=created&limit=200' "$H/reads.log" \
  && ok || bad "P1 run B the two window GETs: $(cat "$H/reads.log")"

# ── P2: merged no-sync with open fresh -> GitHub ─────────────────────────────
fresh p2; board; meta $((NOW - 1000)); rec_lists "$NOW"; rm -f "$W/list-merged.json"
run "$NOW"
github P2 "state=merged miss=no-sync"
eq "P2 the PRR_MISS word" "$(grep -oE "PRR_MISS $S#list why=[a-z-]+" <<<"$LOGS")" "PRR_MISS $S#list why=stale"

# ── P3: the floor ─────────────────────────────────────────────────────────────
fresh p3a; board; meta $((NOW - 3600)); rec_lists "$NOW"; nogh
run "$NOW"
record "P3 age 3600 (knob unset, 3600 applies)"
fresh p3b; board; meta $((NOW - 3601)); rec_lists "$NOW"
run "$NOW"
github "P3 age 3601" "miss=floor"
fresh p3c; board; meta $((NOW - 1000)); rec_lists "$NOW"
run "$NOW" PR_OWNER_LIST_GITHUB_FLOOR_S=0
[ "$(listcalls)" = 2 ] && [ "$(listgets)" = 0 ] && ok || bad "P3 knob 0 wanted GitHub and no record list GET: $(prcalls) / $(cat "$H/reads.log")"
fresh p3d; board; rec_lists "$NOW"
run "$NOW"
github "P3 no meta (first tick)" "miss=floor"
fresh p3e; board; meta $((NOW - 1000)); rec_lists "$NOW"; nogh
run "$NOW" PR_OWNER_LIST_GITHUB_FLOOR_S=1000
record "P3 knob 1000, age 1000"

# ── P4: a needed field is null -> GitHub ──────────────────────────────────────
fresh p4a; board; meta $((NOW - 1000)); rec_lists "$NOW"
jq -c '.missing = "reviews"' "$W/list-open.json" > "$W/t" && mv "$W/t" "$W/list-open.json"
run "$NOW"
github "P4 missing:reviews" "state=open miss=field:reviews"
fresh p4b; board; meta $((NOW - 1000)); rec_lists "$NOW"
jq -c '.missing = "created_at"' "$W/list-merged.json" > "$W/t" && mv "$W/t" "$W/list-merged.json"
run "$NOW"
github "P4 merged missing:created_at" "state=merged miss=field:created_at"

# ── P5: unknown, a wake, the switch -> GitHub ─────────────────────────────────
fresh p5a; board; meta $((NOW - 1000)); rec_lists "$NOW"
jq -c '.unknown = 1' "$W/list-open.json" > "$W/t" && mv "$W/t" "$W/list-open.json"
run "$NOW"
github "P5 unknown:1" "state=open miss=unknown"
fresh p5b; board; meta $((NOW - 1000)); rec_lists "$NOW"; printf 'pr 301 0\n* * 1\n' > "$H/wake"
run "$NOW"
github "P5 a pr wake since the stamp" "miss=wake"
fresh p5c; board; meta $((NOW - 1000)); rec_lists "$NOW"
run "$NOW" WAKE_BACKSTOP=0
github "P5 WAKE_BACKSTOP=0" "miss=wake"
fresh p5d; board; meta $((NOW - 1000)); rec_lists "$NOW"; printf 'issue * 0\n* * 1\n' > "$H/wake"; nogh
run "$NOW"
record "P5 an issue wake only"
fresh p5e; board; meta $((NOW - 1000)); printf '{"ok":true}' > "$W/list-open.json"; printf '{"ok":true}' > "$W/list-merged.json"
run "$NOW"
github "P5 an answer that is not a list answer" "state=open miss=malformed"

# ── P6: PR_RECORD_MAX_AGE_S=0 -> no record list GET ───────────────────────────
fresh p6; board; meta $((NOW - 1000)); rec_lists "$NOW"
run "$NOW" PR_RECORD_MAX_AGE_S=0
[ "$(listcalls)" = 2 ] && ok || bad "P6 knob 0 wanted 2 list reads: $(prcalls)"
eq "P6 GET /api/pr-records" "$(grep -c 'GET /api/pr-records' "$H/reads.log" 2>/dev/null)" 0

# ── P7: the conflict clock ────────────────────────────────────────────────────
p7() { # p7 <case> <dirty_since> [labels-csv for #306]
  fresh "p7$1"; board
  if [ -n "${3:-}" ]; then
    jq --arg l "$3" 'map(if .number == 306 then .labels = [$l | split(",")[] | {name:.}] else . end)' "$H/fx/open.json" > "$H/t" && mv "$H/t" "$H/fx/open.json"
  fi
  meta $((NOW - 1000)); rec_lists "$NOW" 306=
  mkdir -p "$H/state/pr-owners"
  jq -nc --argjson d "$2" '{prs:{"306":{number:306,state:"ORPHAN",since:"2026-09-01T00:00:00Z",reason:"x",key:"BH-306",dirty_since:$d}}}' \
    > "$H/state/pr-owners/example-org_fx.json"
}
DUE=$((NOW - 15 * 86400)); NOTDUE=$((NOW - 2 * 86400))
p7 a "$DUE"
eq "P7 the record row is unknown" "$(jq -r '.rows[] | select(.number == 306) | .mergeable_state' "$W/list-open.json")" null
run "$NOW"
github "P7 unknown + due clock + no label" "miss=conflict"
p7 b "$DUE" stale-conflict; nogh
run "$NOW"
record "P7 unknown + due clock + the label"
grep -q $'^306\tORPHAN\tnone\t' <<<"$(verdicts)" && ok || bad "P7 with the label #306 is action none: $(verdicts)"
p7 c "$NOTDUE"; nogh
run "$NOW"
record "P7 unknown + clock not due"
eq "P7 dirty_since is carried, not reset" "$(jq -r '.prs["306"].dirty_since' "$H/state/pr-owners/example-org_fx.json")" "$NOTDUE"
grep -q $'^306\tORPHAN\thandback:BH-306\t' <<<"$(verdicts)" && ok || bad "P7 not due: the handback arm, as GitHub's UNKNOWN: $(verdicts)"

# P7d: the state file has no clock (the pre-check passes), and the D1 owner
# row carries a due one: the classifier keeps it and labels nothing, because
# only a CONFLICTING head is labelled.
fresh p7d; board; meta $((NOW - 1000)); rec_lists "$NOW" 306=; nogh
jq -nc --argjson d "$DUE" '{as_of:"2026-09-21T14:13:20Z", pr_owners:[{number:306,state:"ORPHAN",since:"2026-09-01T00:00:00Z",reason:"x",key:"BH-306",dirty_since:$d,updated_at:"2026-09-21T14:13:20Z"}]}' > "$W/owners.json"
run "$NOW"
record "P7d a due clock from the D1 rows"
grep -q $'^306\tORPHAN\tnone\t' <<<"$(verdicts)" && ok || bad "P7d an unknown head with a carried due clock is action none: $(verdicts)"
grep -q 'repos/example-org/fx/issues/306/labels' "$H/gh-calls.log" && bad "P7d #306 was labelled: $(grep 306 "$H/gh-calls.log")" || ok

# ── P8: a dry run writes no sync ──────────────────────────────────────────────
fresh p8; board
run "$NOW" PR_OWNER_DRY_RUN=1
[ "$(listcalls)" = 2 ] && ok || bad "P8 wanted the GitHub read: $(prcalls)"
eq "P8 no POST /api/pr-record-lists" "$(grep -c 'POST /api/pr-record-lists' "$H/writes.log" 2>/dev/null)" 0

# ── P9: a full open page is not the whole list ────────────────────────────────
fresh p9; opr 401 ticket/bh-401; opr 402 ticket/bh-402; opr 403 ticket/bh-403
run "$NOW" PR_OWNER_PR_LIMIT=3
eq "P9 only the merged list is posted" "$(posts)" "post-merged.json "
fresh p9b; opr 401 ticket/bh-401; opr 402 ticket/bh-402
run "$NOW" PR_OWNER_PR_LIMIT=3
eq "P9 a shorter page is posted" "$(posts)" "post-merged.json post-open.json "

# ── B1: nothing left the box ──────────────────────────────────────────────────
ESC=$(cat "$T"/c-*/escapes.log 2>/dev/null)
[ -z "$ESC" ] && ok || bad "B1 a call left the fixture worker: $ESC"

echo "pr-owner-sweep-record-list: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
