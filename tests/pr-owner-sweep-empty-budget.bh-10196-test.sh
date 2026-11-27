#!/bin/bash
# tests/pr-owner-sweep-empty-budget.bh-10196-test.sh — bin/pr-owner-sweep.sh
# stops its tick at the first sign that the GitHub core budget is empty
# (the bucket reading state/gh-rest-ledger/.quota-<bucket> says remaining 0
# with a reset still ahead), instead of moving to the next repo or PR.
#
#   Z1  the reading is 0 before the tick: rc 0, no gh call at all (no list,
#       no rate_limit read, no hook read), one "tick stopped before this repo"
#   N1  that tick wrote no state (state/ is the same before and after)
#   Z2  a reading of 1 is not empty: no stop
#   M1  the reading is healthy at the start, the lists come from the record,
#       and GitHub answers the first hook GET 403 with remaining 0: one hook
#       GET in all, the stop line names the next PR, no pr_health flush, no
#       ownerless rollup line, no keyed conductor spawn, rc 0
#   W1  M1 with WAKE_LAUNCH=1: a wake run is not stopped
#   G1  M1 with the lane row lane.pr-owner-sweep.gh_rest_empty_budget_gate=0
#       in the lane gate's settings cache: not stopped
#
# The REAL sweep in its own scratch tree per case, the BH-8481 harness: a gh
# PATH shim that logs every call, a file-backed jobs worker behind a curl shim,
# the real lane gate (it exports LANE_GATE_RUN). Clocks pinned: PR_OWNER_NOW
# and GH_REST_EMPTY_NOW. No network, no sleep.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-empty-budget.bh-10196-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=1790000000                      # pinned: PR_OWNER_NOW, WAKE_BACKSTOP_NOW, GH_REST_EMPTY_NOW
RESET=$((NOW + 600))
OLD=2026-09-01T00:00:00Z
S=example-org/fx; P=fx
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf "$1%.0s" $(seq 40); }
HA=$(sha a)
export GH_REST_EMPTY_NOW="$NOW"
unset WAKE_LAUNCH LANE_GATE_RUN GH_REST_EMPTY_BUDGET_GATE

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
# get403 mode: every REST GET is GitHub's primary-limit answer (remaining 0,
# reset at the epoch the file holds).
case "$*" in
  "api -i -X GET "*) if [ -f "$FX/get403" ]; then
      printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Reset: %s\r\n\r\n{"message":"API rate limit exceeded"}' "$(cat "$FX/get403")"
      exit 1; fi ;;
esac
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
  [ "${P%%\?*}" = /api/ledger ] && printf 'LEDGER %s\n' "$(jq -r '.kind // empty' <<<"$BODY" 2>/dev/null)" >> "$HARNESS/writes.log"
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
  /api/settings/*) ans 200 '{"setting":null}' ;;
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


BKT="pat-$(printf '%s' "$GH_TOKEN" | sha1sum | cut -c1-12)"
reading() { mkdir -p "$H/state/gh-rest-ledger"; printf '%s 5000 %s %s\n' "$1" "$2" "$((NOW - 60))" > "$H/state/gh-rest-ledger/.quota-$BKT"; }
gets() { if [ -f "$H/gh-calls.log" ]; then grep -c '^api -i -X GET ' "$H/gh-calls.log"; else echo 0; fi; }
allcalls() { if [ -f "$H/gh-calls.log" ]; then grep -c . "$H/gh-calls.log"; else echo 0; fi; }
rerun() { # the sweep once more, for its true exit code
  rm -f "${H:?}/gh-calls.log"
  env HARNESS_TEST_SANDBOX=1 WAKE_BACKSTOP_NOW="$NOW" "$@" "$H/bin/pr-owner-sweep.sh" --explain "$P" >/dev/null 2>&1
}
snap() { # every state file but the ledger dir, the lane gate's files, the run claims and the heartbeat (hb_done still ends a stopped tick)
  ( cd "$H/state" && find . -type f ! -path './gh-rest-ledger/*' ! -path './lane-gate/*' ! -path './lane-runs/*' ! -path './heartbeat*' \
      ! -name 'settings-cache.*' -print0 | sort -z | xargs -0 -r md5sum )
}
# Three open ORPHAN PRs, each with a hook GET to make.
board3() {
  opr 501 ticket/bh-501 operator CONFLICTING
  opr 502 ticket/bh-502 operator CONFLICTING
  opr 503 ticket/bh-503 operator CONFLICTING
  mpr 280 ticket/bh-280 2026-08-10T00:00:00Z
}

# ── Z1 / N1: empty before the tick ────────────────────────────────────────────
fresh z1; board3; reading 0 "$RESET"
BEFORE=$(snap)
run "$NOW"
eq "Z1 no gh call at all" "$(allcalls)" 0
grep -q "$S: GitHub core budget empty — tick stopped before this repo; no list, owner or hook read" <<<"$LOGS" && ok \
  || bad "Z1 the stop line: $LOGS"
eq "Z1 one stop line" "$(grep -c 'GitHub core budget empty' <<<"$LOGS")" 1
eq "N1 state/ is unchanged" "$(snap)" "$BEFORE"
eq "N1 no pr_health write" "$(grep -c '^LEDGER pr_health$' "$H/writes.log" 2>/dev/null)" 0
eq "N1 no keyed conductor spawn" "$(cat "$H/spawns.log" 2>/dev/null)" ""
grep -q 'tick totals: repos=0 ' <<<"$LOGS" && ok || bad "Z1 the tick still ends with its totals: $LOGS"
rerun; rc=$?
eq "Z1 rc" "$rc" 0
eq "Z1 rerun: still no gh call" "$(allcalls)" 0

# ── Z2: a reading of 1 is not empty (control) ────────────────────────────────
fresh z2; board3; meta $((NOW - 1000)); rec_lists "$NOW"; reading 1 "$RESET"
run "$NOW"
eq "Z2 remaining 1: no stop line" "$(grep -c 'GitHub core budget empty' <<<"$LOGS")" 0
[ "$(grep -c '^LEDGER pr_health$' "$H/writes.log" 2>/dev/null)" -ge 1 ] && ok || bad "Z2 the health flush runs: $(cat "$H/writes.log" 2>/dev/null)"

# ── M1: the bucket empties on the first hook GET ─────────────────────────────
m1() { # m1 <case> [VAR=val...]
  local c="$1"; shift
  fresh "$c"; board3; meta $((NOW - 1000)); rec_lists "$NOW"; reading 4000 "$RESET"
  printf '%s\n' "$RESET" > "$H/fx/get403"
  run "$NOW" "$@"
}
m1 m1
eq "M1 exactly one hook GET reached GitHub" "$(gets)" 1
eq "M1 no list read" "$(grep -c 'pr list' "$H/gh-calls.log" 2>/dev/null)" 0
FIRST=$(grep -m1 '^api -i -X GET ' "$H/gh-calls.log" | grep -oE '/(issues|pulls)/[0-9]+' | grep -oE '[0-9]+$')
SECOND=$(verdicts | awk -F'\t' -v f="$FIRST" 'seen && $1 != "" {print $1; exit} $1 == f {seen=1}')
grep -q "$S#$SECOND: GitHub core budget empty — tick stopped at this PR; it and the PRs after it are left as they are" <<<"$LOGS" && ok \
  || bad "M1 the stop line names the PR after #$FIRST (#$SECOND): $(grep 'budget empty' <<<"$LOGS")"
eq "M1 one stop line" "$(grep -c 'GitHub core budget empty' <<<"$LOGS")" 1
eq "M1 no pr_health flush" "$(grep -c '^LEDGER pr_health$' "$H/writes.log" 2>/dev/null)" 0
eq "M1 no keyed conductor spawn" "$(cat "$H/spawns.log" 2>/dev/null)" ""
# The ownerless rollup and its clock sit behind the same stop; the fixture
# cannot reach the clock's settings write (ph_streak), so the rollup line is
# the observable (W1 proves it is written when the tick is not stopped).
grep -q "$S: ownerless=" <<<"$LOGS" && bad "M1 no ownerless rollup line after the stop" || ok
grep -q "\[gh-empty-budget\] lane=pr-owner-sweep " "$H/logs/gh-rate.log" 2>/dev/null && ok \
  || bad "M1 gh_rest said the refusal: $(cat "$H/logs/gh-rate.log" 2>/dev/null)"
rerun; rc=$?
eq "M1 rc (rerun on the empty reading)" "$rc" 0

# ── W1: a wake-started run is not stopped ────────────────────────────────────
m1 w1 WAKE_LAUNCH=1
[ "$(gets)" -gt 1 ] && ok || bad "W1 a wake run sends every hook GET, got $(gets)"
eq "W1 no stop line" "$(grep -c 'GitHub core budget empty' <<<"$LOGS")" 0
[ "$(grep -c '^LEDGER pr_health$' "$H/writes.log" 2>/dev/null)" -ge 1 ] && ok || bad "W1 the health flush runs"
grep -q "$S: ownerless=" <<<"$LOGS" && ok || bad "W1 the ownerless rollup line"

# ── G1: the lane row turns the rule off ──────────────────────────────────────
fresh g1; board3; meta $((NOW - 1000)); rec_lists "$NOW"; reading 4000 "$RESET"
printf '%s\n' "$RESET" > "$H/fx/get403"
printf '{"values":{"lane.pr-owner-sweep.gh_rest_empty_budget_gate":"0"}}\n' > "$H/state/settings-cache.json"
run "$NOW"
[ "$(gets)" -gt 1 ] && ok || bad "G1 row 0: every hook GET is sent, got $(gets)"
eq "G1 no stop line" "$(grep -c 'GitHub core budget empty' <<<"$LOGS")" 0

ESC=$(cat "$T"/c-*/escapes.log 2>/dev/null)
[ -z "$ESC" ] && ok || bad "B1 a call left the fixture worker: $ESC"

echo "pr-owner-sweep-empty-budget.bh-10196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
