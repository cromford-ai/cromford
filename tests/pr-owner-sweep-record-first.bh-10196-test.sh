#!/bin/bash
# tests/pr-owner-sweep-record-first.bh-10196-test.sh — bin/pr-owner-sweep.sh
# reads its open and merged lists from the PR record (pr_records) first;
# `gh pr list` (GraphQL) is the fallback on a miss.
#
# The floor (PR_OWNER_LIST_GITHUB_FLOOR_S, fallback 3600) used to be a miss on
# its own: a copy older than it, or no copy at all, always read GitHub, which
# is 2 GraphQL list calls per repo per hour. Now an expired floor is a miss
# only when the record's open list holds a row with an unknown
# mergeable_state (NULL, unknown, draft): the one gap the floor exists for.
#
#   R1  no openlist.meta (first tick), every open row known -> record, 0 list calls
#   R2  meta 7200 s old, every row known -> record
#   R3  meta 7200 s old, one open row mergeable_state NULL -> GitHub, miss=floor
#   R4  one row `draft` -> miss=floor; one row `unknown`, no meta -> miss=floor
#   R5  an empty open list, no meta -> record
#   R6  PR_OWNER_LIST_GITHUB_FLOOR_S=0 -> GitHub, 0 record list GETs
#   R7  inside the floor (age 3600) with a NULL row and no due clock -> record
#
# The REAL sweep in a scratch tree per case (the BH-8481 harness). Clocks
# pinned (PR_OWNER_NOW). No network, no sleep.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-record-first.bh-10196-test.sh
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
OLD=2026-09-01T00:00:00Z
S=example-org/fx; P=fx
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf "$1%.0s" $(seq 40); }
HA=$(sha a)

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


board() {
  opr 301 ticket/bh-301 operator
  opr 302 ticket/bh-302 operator MERGEABLE parked
  opr 303 feature/contrib someone-else
  opr 306 ticket/bh-306 operator CONFLICTING
  mpr 280 ticket/bh-280 2026-08-10T00:00:00Z
}

# ── R1: first tick, every open row known ─────────────────────────────────────
fresh r1; board; rec_lists "$NOW" 306=dirty,302=blocked; nogh
run "$NOW"
record "R1 no meta, all rows known"
eq "R1 no miss=floor line" "$(recmiss miss=floor)" 0
[ -n "$(verdicts)" ] && ok || bad "R1 the sweep classified the record's PRs: $OUT"

# ── R2: the floor has expired, every open row known ──────────────────────────
fresh r2; board; meta $((NOW - 7200)); rec_lists "$NOW" 306=dirty; nogh
run "$NOW"
record "R2 age 7200, all rows known"

# ── R3/R4: the floor has expired and one row is unknown ──────────────────────
fresh r3; board; meta $((NOW - 7200)); rec_lists "$NOW" 306=
eq "R3 the record row is NULL" "$(jq -r '.rows[] | select(.number == 306) | .mergeable_state' "$W/list-open.json")" null
run "$NOW"
github "R3 age 7200, one NULL row" "miss=floor"
fresh r4a; board; meta $((NOW - 7200)); rec_lists "$NOW" 306=draft
run "$NOW"
github "R4 one draft row" "miss=floor"
fresh r4b; board; rec_lists "$NOW" 301=unknown
run "$NOW"
github "R4 one unknown row, no meta" "miss=floor"

# ── R5: an empty open list, no meta ──────────────────────────────────────────
fresh r5; echo '[]' > "$H/fx/open.json"; mpr 280 ticket/bh-280 2026-08-10T00:00:00Z; rec_lists "$NOW"; nogh
run "$NOW"
eq "R5 no GitHub list read" "$(listcalls)" 0
eq "R5 no miss=floor line" "$(recmiss miss=floor)" 0

# ── R6: the knob at 0 is the record tier off ─────────────────────────────────
fresh r6; board; rec_lists "$NOW" 306=dirty
run "$NOW" PR_OWNER_LIST_GITHUB_FLOOR_S=0
[ "$(listcalls)" = 2 ] && [ "$(listgets)" = 0 ] && ok || bad "R6 knob 0 wanted GitHub and no record list GET: $(prcalls) / $(cat "$H/reads.log")"

# ── R7: inside the floor a NULL row is still the record (as before) ──────────
fresh r7; board; meta $((NOW - 3600)); rec_lists "$NOW" 306=; nogh
run "$NOW"
record "R7 age 3600, one NULL row, no due clock"

ESC=$(cat "$T"/c-*/escapes.log 2>/dev/null)
[ -z "$ESC" ] && ok || bad "B1 a call left the fixture worker: $ESC"

echo "pr-owner-sweep-record-first.bh-10196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
