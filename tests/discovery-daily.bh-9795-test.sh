#!/bin/bash
# tests/discovery-daily.bh-9795-test.sh — BH-9795: the discovery-daily lane
# (part 1: the Sentry source). Drives the REAL bin/discovery-daily.sh and
# bin/discovery-setup.sh in a scratch harness. Modeled on
# tests/sentry-triage.bh-5620-test.sh.
#
# The lane's closure is installed with scratch_install_closure. Stubs:
#   - a fake `curl` first on PATH answers the Sentry REST paths from $FXT and
#     logs every call to $FXT/curl.log; a fake `gh` fails the suite if called;
#   - $H/bin/agent-call.sh records argv and the AGENT_CALL_* env to ac.log,
#     copies the prompt, writes $FXT/answer.txt to its out file, appends one
#     26-column cost row under COST_RUN_ID when $FXT/cost.usd exists, and exits
#     $FXT/ac.rc;
#   - $H/bin/lane-alert.sh, $H/bin/archie-tg-send.sh and $H/bin/harness-ctl.sh
#     record their argv;
#   - DISCOVERY_DAILY_FIXTURE (sandbox-only seam) defines a file-backed
#     job_ledger_row/put/claim and setting_get, lane_role_model /
#     lane_model_ladder, and gh_rest / gh_rest_comment / gh_rest_issue_list.
#
#   D1  a new Sentry issue with 5 events: one create, body sections and marker
#   D2  a second run on the same date: no fetch, no call
#   D3  the raw list file; the raw prune by DISCOVERY_RAW_KEEP_D
#   D4  ticketed row and open marker drop the item; near misses still get a call
#   D5  below the event floor; a noise answer
#   D6  six fileable items, TICKETS_DAY 5: five creates
#   D7  no token or no project slug: not-configured, no fetch
#   D8  the call line and the untrusted frame
#   D9  attempts, the failed alert, rc 75; the hotfix edge
#   D10 the id and url in the body come from the fetch, never from the model
#   D11 0 real vendor calls
#   D12 no model literal; the route role
#   D13 a lane-filed open ticket is never an item
#   D14 the kill switch
#   D15 the summary and its cost
#   D16 the decision table
#   D17 bin/discovery-setup.sh is idempotent and validates
#   D18 the missed-run check
#   D19 the composed schema
#   S1  DISCOVERY_SOURCES is checked before any file is loaded (review fix)
#   T1  DISCOVERY_TARGET_REPO: a fleet.conf repo is used; any other value reads nothing (review fix)
#   N1  the detail, candidate-match and title cuts are knobs (review fix)
#   N2  the missed-run marker retention is a knob (review fix)
#   N3  calls with no cost row: usd unknown, not 0 (review fix)
#   N4  a retry row past the attempts: failed and one failed alert (review fix)
#   M1  model text cannot plant a marker in a ticket or a comment (BH-9820 item 1)
#   M2  bin/discovery-setup.sh writes the since row once (BH-9820 item 2)
#   M3  the missed-run alert: alert_digest, held open, closed by a later done run (BH-9820 items 4, 5)
#   M4  the project env file gives only DISCOVERY_SENTRY_TOKEN (BH-9820 item 6)
#   M5  bin/discovery-setup.sh --sentry-org (BH-9820 item 6)
#   M6  a 401/403/404 list: one log line with org and slug, no token (BH-9820 item 6)
#   M7  the run-claim stale pad is a knob (BH-9820 item 4)
#   R   the registry knobs
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/discovery-daily.bh-9795-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "discovery-daily: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

for f in bin/discovery-daily.sh bin/lib/discovery-daily.sh bin/lib/discovery/sentry.sh \
         bin/lib/discovery/rules.sh bin/lib/discovery-missed.sh bin/discovery-setup.sh \
         catalog/lanes.d/discovery-daily.json cron/lanes/782-discovery-daily.cron \
         catalog/prompts/discovery-daily.md docs/DISCOVERY-DAILY.md; do
  [ -f "$DIR/$f" ] && ok || bad "missing $f"
done
[ -f "$DIR/bin/discovery-daily.sh" ] || { echo "discovery-daily: $PASS passed, $FAIL failed"; exit 1; }

H="$T/h"
export FXT="$T/fx"
mkdir -p "$H/env" "$H/catalog/prompts" "$T/fakebin"
scratch_install_closure bin/discovery-daily.sh "$H" >/dev/null || bad "closure install failed"
scratch_install_closure bin/discovery-setup.sh "$H" >/dev/null || bad "setup closure install failed"
scratch_install_closure bin/lib/discovery-missed.sh "$H" >/dev/null || bad "missed-check closure install failed"
for f in bin/lib/discovery/sentry.sh bin/lib/discovery/rules.sh bin/lib/discovery-missed.sh; do
  mkdir -p "$H/$(dirname "$f")"; cp "$DIR/$f" "$H/$f"
done
cp "$DIR/catalog/prompts/discovery-daily.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
printf '%s\n' "project-6-os  example-org/project-6  https://os.example.com  -  1  box-fixture 127.0.0.1" \
  "other-os  example-org/other-os  https://other.example.com  -  2  box-fixture 127.0.0.1" > "$H/fleet.conf"
rm -f "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh" "$H/bin/harness-ctl.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
{ printf 'call'; printf ' [%s]' "$@"; env | grep -E '^AGENT_CALL_' | sort | tr '\n' ' '; printf '\n'; } >> "$FXT/ac.log"
case "$6" in @*) cp "${6#@}" "$FXT/prompt.last" 2>/dev/null ;; esac
# The item rows as the ledger holds them DURING the call (the attempt is written first).
for f in "$FXT"/ledger/discovery-daily.*; do [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(jq -c '[.status, (.detail | fromjson? | .attempts)]' "$f")"; done >> "$FXT/at-call.log"
cat "$FXT/answer.txt" > "$5" 2>/dev/null
if [ -f "$FXT/cost.usd" ]; then
  u=$(cat "$FXT/cost.usd")
  printf '2026-11-18T00:00:00Z,box,%s,discovery-daily,claude,stub-model,0,1,100,50,,,%s,api,,,,,,,,,%s,,,\n' "$2" "$u" "${COST_RUN_ID:-}" >> "$HARNESS/logs/cost.csv"
fi
exit "$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >> "$FXT/tg.log"
exit 0
SH
cat > "$H/bin/harness-ctl.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/ctl.log"
# set <lane> <ENV> <value> <project>: the row the next setting_get reads.
k=$(printf 'lane.%s.%s.%s' "$2" "$5" "$3" | tr '[:upper:]' '[:lower:]')
mkdir -p "$FXT/settings"; printf '%s' "$4" > "$FXT/settings/$k"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh" "$H/bin/harness-ctl.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
out=""; prev=""; m=GET
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) m="$a" ;; esac
  # BH-9820: the bearer each call carries, and the GH_TOKEN the lane passed on.
  case "$prev $a" in "-H Authorization: "*) printf '%s GH_TOKEN=%s\n' "${a#Authorization: }" "${GH_TOKEN-<unset>}" >> "$FXT/auth.log" ;; esac
  prev="$a"
done
url="${!#}"
printf '%s %s\n' "$m" "$url" >> "$FXT/curl.log"
code=200; body='{}'
case "$url" in
  */projects/*/issues/*) body=$(cat "$FXT/issues.json"); code=$(cat "$FXT/list.code" 2>/dev/null || echo 200) ;;
  */events/latest/*) id=$(printf '%s' "$url" | sed -n 's#.*/issues/\([^/]*\)/events/latest/.*#\1#p')
                     body=$(cat "$FXT/event-$id.json" 2>/dev/null || echo '{}') ;;
  */comments/*) code=201; body='{"detail":"fixture"}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
printf '%s' "$code"
exit 0
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$FXT/realgh.log"
exit 1
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

cat > "$T/fixture.sh" <<'SH'
job_ledger_row() {
  printf 'row %s %s\n' "$1" "$2" >> "$FXT/ledger.log"
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  local f="$FXT/ledger/$1.${2//\//+}"
  [ -f "$f" ] || return 2
  cat "$f"
}
job_ledger_put() {
  printf 'put %s %s %s\n' "$1" "$2" "$3" >> "$FXT/ledger.log"
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d[0:4000]}' > "$FXT/ledger/$1.${2//\//+}"
}
job_ledger_claim() {
  printf 'claim %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$FXT/ledger.log"
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  local f="$FXT/ledger/$1.${2//\//+}" st
  if [ -f "$f" ]; then
    st=$(jq -r .status "$f")
    case ",$5," in *",$st,"*) printf '%s' "$st"; return 3 ;; esac
    [ "$st" = "$3" ] && { printf '%s' "$st"; return 3; }
  fi
  jq -nc --arg s "$3" '{status:$s, detail:""}' > "$f"
  printf '%s' "$3"
}
setting_get() {
  [ "$(cat "$FXT/settings.rc" 2>/dev/null)" = 1 ] && return 1
  [ -f "$FXT/settings/$1" ] || return 2
  cat "$FXT/settings/$1"
}
lane_role_model() { echo "$1" >> "$FXT/roles.log"; echo stub-model; }
lane_model_ladder() { printf '0\tstub-model\tclaude\n'; }
gh_rest() {
  local m=$1 p=$2 f=""; shift 2
  [ "${1:-}" = --input ] && f=$2
  if [ -n "$f" ]; then printf '%s %s %s\n' "$m" "$p" "$(jq -c . "$f")" >> "$FXT/gh.log"
  else printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"; fi
  case "$m $p" in
    "GET "*/comments) GH_REST_STATUS=200; cat "$FXT/comments.json" 2>/dev/null || echo '[]'; return 0 ;;
  esac
  GH_REST_STATUS=201
  printf '{"number":9001,"html_url":"https://github.com/example-org/example-repo/issues/9001"}'
}
gh_rest_comment() { printf 'COMMENT %s %s %s\n' "$1" "$2" "$(jq -Rsc . "$3")" >> "$FXT/gh.log"; GH_REST_STATUS=201; }
gh_rest_issue_list() { printf 'LIST %s %s %s %s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$FXT/gh.log"; GH_REST_STATUS=200; cat "$FXT/open.json"; }
SH

NOW=1791676800
DAY=$(date -u -d "@$NOW" +%F)
LOG="$H/logs/discovery-daily.log"
P=project-6-os

# mkissue <id> <count> [24h events]
mkissue() {
  jq -nc --arg id "$1" --arg c "$2" --argjson s "${3:-4}" '{
    id: $id, shortId: ("project-6-" + $id), title: ("Example error " + $id),
    permalink: ("https://sentry.example.com/issues/" + $id + "/"), count: $c,
    firstSeen: "2026-11-10T00:00:00Z", lastSeen: "2026-11-17T23:00:00Z",
    status: "unresolved", substatus: "ongoing",
    stats: {"24h": [[1791673200, ($s / 2 | floor)], [1791676800, ($s - ($s / 2 | floor))]]}}'
}
mkevent() {
  jq -nc '{message: "fixture message", title: "Example error", dateCreated: "2026-11-17T00:00:00Z",
    tags: [{key: "project", value: "example-project"}],
    entries: [{type: "exception", data: {values: [{type: "Error", value: "boom",
      stacktrace: {frames: [{filename: "app/checkout.ts", function: "save", lineNo: 12}]}}]}}]}' > "$FXT/event-$1.json"
}
answer_ticket() {
  printf '%s\n' '{"answers":{"known_benign":"no","user_impact":"yes","own_code":"yes","same_ticket":0},"draft":{"title":"Checkout save fails — on a null cart","cause":"The save handler reads a null cart.","evidence":"The stack ends in save.","proposed_fix":"Guard the null cart.","acceptance_tests":["T1: a null cart saves."]}}' > "$FXT/answer.txt"
}
answer_noise() {
  printf '%s\n' '{"answers":{"known_benign":"yes","user_impact":"no","own_code":"no","same_ticket":0},"draft":{"title":"","cause":"","evidence":"","proposed_fix":"","acceptance_tests":[]}}' > "$FXT/answer.txt"
}
reset() {
  scratch_rm "$FXT"; mkdir -p "$FXT/ledger" "$FXT/settings"
  for x in "$LOG" "$H/flags/lane-off-discovery-daily" "$H/flags/all-off" "$H/state/discovery-daily" "$H/logs/cost.csv"; do scratch_rm "$x"; done
  echo '[]' > "$FXT/open.json"; echo 0 > "$FXT/ac.rc"; echo '[]' > "$FXT/issues.json"
  answer_ticket
}
# run [VAR=value...]: one lane run at $NOW (or RUN_NOW).
run() {
  env HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 DISCOVERY_DAILY_NOW="${RUN_NOW:-$NOW}" \
    DISCOVERY_DAILY_FIXTURE="$T/fixture.sh" SENTRY_API_TOKEN=tok-fixture-1 JOBS_URL= JOBS_BOX=box-fixture \
    DISCOVERY_SOURCES=sentry DISCOVERY_SENTRY_PROJ=project-6-web FLEET_CONF="$H/fleet.conf" \
    "$@" bash "$H/bin/discovery-daily.sh" "$P" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
calls()   { if [ -f "$FXT/ac.log" ]; then wc -l < "$FXT/ac.log"; else echo 0; fi; }
creates() { if [ -f "$FXT/gh.log" ]; then grep -c '^POST repos/.*/issues ' "$FXT/gh.log"; else echo 0; fi; }
curls()   { if [ -f "$FXT/curl.log" ]; then wc -l < "$FXT/curl.log"; else echo 0; fi; }
lfile()   { printf '%s/ledger/discovery-daily.%s' "$FXT" "$(printf '%s' "$P/sentry/$1" | tr '/' '+')"; }
lstat()   { jq -r .status "$(lfile "$1")" 2>/dev/null; }
ldet()    { jq -r ".detail | fromjson | $2" "$(lfile "$1")" 2>/dev/null; }
runrow()  { cat "$FXT/ledger/discovery-daily-run.$P+${1:-$DAY}" 2>/dev/null; }
summary() { grep ' discovery-daily ' "$LOG" 2>/dev/null | grep ' read=' | tail -1; }
lastbody() { grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | tail -n 1 | cut -d' ' -f3- | jq -r .body 2>/dev/null; }

# ── D1: a new Sentry issue with 5 events → one ticket ────────────────────────
reset; mkissue 101 5 | jq -s . > "$FXT/issues.json"; mkevent 101
run
check "D1 rc 0 (got $(cat "$T/rc"); $(head -c 300 "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "D1 one model call ($(calls))" '[ "$(calls)" = 1 ]'
check "D1 exactly one create on example-org/project-6 ($(creates))" '[ "$(grep -c "^POST repos/example-org/project-6/issues " "$FXT/gh.log" 2>/dev/null)" = 1 ]'
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "D1 label ai-build" 'jq -e ".labels | index(\"ai-build\")" <<<"$PAY" >/dev/null 2>&1'
check "D1 no hotfix at 4 events in 24h" '! jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'
BODY=$(jq -r .body <<<"$PAY" 2>/dev/null)
check "D1 body sections" 'grep -qx "## Scope" <<<"$BODY" && grep -qx "## Acceptance tests" <<<"$BODY" && grep -qx "## Out of scope" <<<"$BODY"'
check "D1 body has the marker" 'grep -qxF "<!-- discovery: sentry/101 -->" <<<"$BODY"'
check "D1 body has the fetched url" 'grep -qF "https://sentry.example.com/issues/101/" <<<"$BODY"'
check "D1 title prefix" 'jq -r .title <<<"$PAY" 2>/dev/null | grep -q "^Sentry 101: Checkout save fails - on a null cart"'
check "D1 no em or en dash" '[ -n "$PAY" ] && ! jq -r ".title, .body" <<<"$PAY" | grep -q "[—–]"'
check "D1 row ticketed filed #9001 ($(lstat 101))" '[ "$(lstat 101)" = ticketed ] && [ "$(ldet 101 .action)" = filed ] && [ "$(ldet 101 .issue)" = 9001 ]'
check "D1 day row lists sentry/101" '[ "$(jq -r ".detail | fromjson | .filed | index(\"sentry/101\")" "$FXT/ledger/discovery-daily-day.$P+$DAY" 2>/dev/null)" = 0 ]'
check "D1 run row done with filed=1" '[ "$(runrow | jq -r .status)" = done ] && [ "$(runrow | jq -r ".detail | fromjson | .filed")" = 1 ]'
check "D1 summary filed=1 calls=1 [$(summary)]" '[[ "$(summary)" == *" calls=1 "*"filed=1 "* ]]'
check "D1 writeback posted once" '[ "$(grep -c "^POST .*/issues/101/comments/" "$FXT/curl.log")" = 1 ]'
check "D1 the attempt row is written before the call [$(cat "$FXT/at-call.log" 2>/dev/null)]" 'grep -qx "discovery-daily.$P+sentry+101 \[\"retry\",1\]" "$FXT/at-call.log"'
check "D1 since row written" '[ "$(jq -r ".detail | fromjson | .since" "$FXT/ledger/discovery-daily-since.$P" 2>/dev/null)" = "$DAY" ]'
check "D1 no token in the log" '! grep -q tok-fixture-1 "$LOG"'
# The adapter's list line, read straight from the adapter.
LINE=$(cd "$T" && env HARNESS="$H" PATH="$T/fakebin:$PATH" SENTRY_API_TOKEN=tok-fixture-1 DISCOVERY_SENTRY_PROJ=project-6-web \
  bash -c '. "$HARNESS/bin/lib/sentry-triage.sh"; . "$HARNESS/bin/lib/discovery/sentry.sh"; mkdir -p "$1"; dd_src_sentry_list "$1"' _ "$T/adapter-raw" 2>/dev/null | head -1)
check "D1 the list line has the 7 ticket fields [$LINE]" '[ "$(jq -c "[.source, .id, .title, .url, .count, .first_seen, .last_seen]" <<<"$LINE" 2>/dev/null)" = "[\"sentry\",\"101\",\"Example error 101\",\"https://sentry.example.com/issues/101/\",5,\"2026-11-10T00:00:00Z\",\"2026-11-17T23:00:00Z\"]" ]'
check "D1 the list line carries count_24h" '[ "$(jq -r .count_24h <<<"$LINE" 2>/dev/null)" = 4 ]'

# ── D2: the same date again → no fetch, no call ──────────────────────────────
C0=$(curls)
run
check "D2 no new curl ($C0 -> $(curls))" '[ "$(curls)" = "$C0" ]'
check "D2 still one call ($(calls))" '[ "$(calls)" = 1 ]'
check "D2 one log line names done" 'grep -q "already done" "$LOG"'

# ── D3: the raw list file; the prune ─────────────────────────────────────────
reset; mkissue 103 5 | jq -s . > "$FXT/issues.json"; mkevent 103
OLD15=$(date -u -d "@$((NOW - 15 * 86400))" +%F); OLD13=$(date -u -d "@$((NOW - 13 * 86400))" +%F)
mkdir -p "$H/state/discovery-daily/$P/$OLD15" "$H/state/discovery-daily/$P/$OLD13"
run
check "D3 raw list file" 'jq -e "length == 1" "$H/state/discovery-daily/$P/$DAY/sentry-list.json" >/dev/null 2>&1'
check "D3 raw event file" '[ -s "$H/state/discovery-daily/$P/$DAY/event-103.json" ]'
check "D3 a 15-day dir is pruned" '[ ! -d "$H/state/discovery-daily/$P/$OLD15" ]'
check "D3 a 13-day dir stays" '[ -d "$H/state/discovery-daily/$P/$OLD13" ]'

# ── D4: code drops; near misses still called ─────────────────────────────────
reset; { mkissue 201 9; mkissue 202 8; mkissue 203 7; mkissue 204 6; } | jq -s . > "$FXT/issues.json"
for i in 201 202 203 204; do mkevent $i; done
jq -nc '{status: "ticketed", detail: ({source: "sentry", id: "201", action: "filed"} | tojson)}' > "$(lfile 201)"
jq -nc '[{number: 301, title: "x", body: "a\n<!-- discovery: sentry/202 -->\n"},
         {number: 302, title: "y", body: "b\n<!-- discovery: sentry/2031 -->\n"},
         {number: 303, title: "z", body: "c\n<!-- sentry-issue: 204 -->\n"}]' > "$FXT/open.json"
run
check "D4 two calls: the near misses ($(calls))" '[ "$(calls)" = 2 ]'
check "D4 the near misses were called" 'grep -q "Example error 203" "$FXT/prompt.last" || grep -q "Example error 204" "$FXT/prompt.last"'
check "D4 202 healed from the marker on #301" '[ "$(lstat 202)" = ticketed ] && [ "$(ldet 202 .action)" = healed ] && [ "$(ldet 202 .issue)" = 301 ]'
check "D4 201 untouched" '[ "$(ldet 201 .action)" = filed ]'
check "D4 the open list reads every open issue (no label)" 'grep -q "^LIST example-org/project-6 open  1000$" "$FXT/gh.log"'
check "D4 summary dropped=2 [$(summary)]" '[[ "$(summary)" == *" dropped=2 "* ]]'

# ── D5: below the floor; a noise answer ──────────────────────────────────────
reset; { mkissue 205 2; mkissue 206 3; } | jq -s . > "$FXT/issues.json"; mkevent 205; mkevent 206
answer_noise
run
check "D5 one call (count 3 is the edge) ($(calls))" '[ "$(calls)" = 1 ]'
check "D5 below the floor: no row" '[ ! -e "$(lfile 205)" ]'
check "D5 noise row with the rule reason" '[ "$(lstat 206)" = noise ] && [ "$(ldet 206 .reason)" = known-benign ]'
check "D5 no create" '[ "$(creates)" = 0 ]'

# ── D6: six fileable items, TICKETS_DAY 5 ────────────────────────────────────
reset; for i in 1 2 3 4 5 6; do mkissue "60$i" "$((20 - i))"; mkevent "60$i"; done | jq -s . > "$FXT/issues.json"
run DISCOVERY_TICKETS_DAY=5
check "D6 five creates ($(creates))" '[ "$(creates)" = 5 ]'
check "D6 five calls ($(calls))" '[ "$(calls)" = 5 ]'
check "D6 the sixth has no row" '[ ! -e "$(lfile 606)" ]'
check "D6 summary capped=1 [$(summary)]" '[[ "$(summary)" == *" capped=1"* ]]'
# The call cap stops the loop too.
reset; for i in 1 2 3; do mkissue "61$i" "$((20 - i))"; mkevent "61$i"; done | jq -s . > "$FXT/issues.json"
answer_noise
run DISCOVERY_MAX_CALLS_DAY=2
check "D6 MAX_CALLS_DAY=2: two calls ($(calls))" '[ "$(calls)" = 2 ] && [ ! -e "$(lfile 613)" ]'

# ── D7: not configured ───────────────────────────────────────────────────────
reset; mkissue 107 9 | jq -s . > "$FXT/issues.json"; mkevent 107
run SENTRY_API_TOKEN=
check "D7 no token: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "D7 no token: one not-configured line" '[ "$(grep -c "sentry not-configured" "$LOG")" = 1 ]'
check "D7 no token: no curl" '[ "$(curls)" = 0 ]'
check "D7 no token: run row done, not_configured=1" '[ "$(runrow | jq -r .status)" = done ] && [ "$(runrow | jq -r ".detail | fromjson | .not_configured")" = 1 ]'
reset; mkissue 117 9 | jq -s . > "$FXT/issues.json"; mkevent 117
run DISCOVERY_SENTRY_PROJ=
check "D7 no slug: not-configured, no curl" 'grep -q "sentry not-configured" "$LOG" && [ "$(curls)" = 0 ] && [ "$(runrow | jq -r .status)" = done ]'

# ── D8: the call line and the untrusted frame ────────────────────────────────
reset; mkissue 108 9 | jq -s . > "$FXT/issues.json"; mkevent 108
run
check "D8 agent-call argv" 'grep -q "^call \[discovery-daily\] \[project-6-os\] \[stub-model\] \[300\]" "$FXT/ac.log"'
check "D8 agent-call env" 'grep -q "AGENT_CALL_NO_TOOLS=1" "$FXT/ac.log" && grep -q "AGENT_CALL_BUDGET_USD_DISCOVERY_DAILY=0.50" "$FXT/ac.log" && grep -q "AGENT_CALL_LANE=discovery-daily" "$FXT/ac.log" && grep -q "AGENT_CALL_RUNNERS=claude" "$FXT/ac.log"'
INFRAME=$(awk '/^=== UNTRUSTED INPUT /{f=1; next} /^=== END UNTRUSTED INPUT /{f=0} f' "$FXT/prompt.last" 2>/dev/null)
check "D8 the fetched title is inside an untrusted frame" 'grep -q "Example error 108" <<<"$INFRAME"'
check "D8 the title is not outside a frame" '! awk "/^=== UNTRUSTED INPUT /{f=1; next} /^=== END UNTRUSTED INPUT /{f=0; next} !f" "$FXT/prompt.last" | grep -q "Example error 108"'
check "D8 the questions are in the prompt" 'grep -q known_benign "$FXT/prompt.last" && grep -q same_ticket "$FXT/prompt.last"'

# ── D9: attempts, the failed alert, rc 75; the hotfix edge ───────────────────
reset; mkissue 109 9 | jq -s . > "$FXT/issues.json"; mkevent 109
echo 1 > "$FXT/ac.rc"
RUN_NOW=$NOW run; A1="$(lstat 109)/$(ldet 109 .attempts)"
RUN_NOW=$((NOW + 86400)) run; A2="$(lstat 109)/$(ldet 109 .attempts)"
RUN_NOW=$((NOW + 2 * 86400)) run; A3="$(lstat 109)/$(ldet 109 .attempts)"
check "D9 retry/1 retry/2 failed/3 (got $A1 $A2 $A3)" '[ "$A1 $A2 $A3" = "retry/1 retry/2 failed/3" ]'
check "D9 exactly one failed alert" '[ "$(grep -c "discovery-daily-failed" "$FXT/alerts.log" 2>/dev/null)" = 1 ]'
RUN_NOW=$((NOW + 3 * 86400)) run
check "D9 a fourth run: no call ($(calls)), still one alert" '[ "$(calls)" = 3 ] && [ "$(grep -c "discovery-daily-failed" "$FXT/alerts.log")" = 1 ]'
reset; mkissue 119 9 | jq -s . > "$FXT/issues.json"; mkevent 119
echo 1 > "$FXT/ac.rc"; RUN_NOW=$NOW run
echo 75 > "$FXT/ac.rc"; RUN_NOW=$((NOW + 86400)) run
check "D9 rc 75 keeps attempts at 1 ($(lstat 119)/$(ldet 119 .attempts))" '[ "$(lstat 119)" = retry ] && [ "$(ldet 119 .attempts)" = 1 ] && [ "$(ldet 119 .last_rc)" = 75 ]'
reset; mkissue 129 80 50 | jq -s . > "$FXT/issues.json"; mkevent 129
run
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "D9 50 events in 24h: hotfix" 'jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'
reset; mkissue 139 80 49 | jq -s . > "$FXT/issues.json"; mkevent 139
run
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "D9 49 events in 24h: no hotfix" '[ -n "$PAY" ] && ! jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'

# ── D10: the id and url come from the fetch ─────────────────────────────────
reset; mkissue 101 9 | jq -s . > "$FXT/issues.json"; mkevent 101
printf '%s\n' '{"answers":{"known_benign":"no","user_impact":"yes","own_code":"yes","same_ticket":0},"draft":{"title":"Save fails","cause":"The save handler fails.","evidence":"Sentry issue 999 at https://sentry.example.com/issues/999/","source_id":"999","url":"https://sentry.example.com/issues/999/","proposed_fix":"Fix it.","acceptance_tests":["T1: it saves."]}}' > "$FXT/answer.txt"
run
B10=$(lastbody)
check "D10 the body names 101 and its fetched url" 'grep -qF "https://sentry.example.com/issues/101/" <<<"$B10" && grep -qxF "<!-- discovery: sentry/101 -->" <<<"$B10"'
check "D10 the body never names 999" '[ -n "$B10" ] && ! grep -q 999 <<<"$B10"'

# ── D11: 0 real vendor calls ─────────────────────────────────────────────────
check "D11 the real gh was never called" '[ ! -e "$FXT/realgh.log" ]'
reset; mkissue 111 9 | jq -s . > "$FXT/issues.json"; mkevent 111
run
check "D11 every curl went to the fixture Sentry host" '[ "$(curls)" -gt 0 ] && ! grep -v " https://sentry.io/api/0/" "$FXT/curl.log" | grep -q .'
check "D11 the only Sentry POST is the one writeback" '[ "$(grep -c "^POST " "$FXT/curl.log")" = 1 ] && grep -q "^POST https://sentry.io/api/0/issues/111/comments/$" "$FXT/curl.log"'
check "D11 the real gh was never called" '[ ! -e "$FXT/realgh.log" ]'

# ── D12: no model literal; the route role ────────────────────────────────────
HITS=$(grep -nE 'claude-[a-z0-9]' "$DIR/bin/discovery-daily.sh" "$DIR/bin/lib/discovery-daily.sh" "$DIR/bin/lib/discovery/sentry.sh" \
  "$DIR/bin/lib/discovery/rules.sh" "$DIR/bin/lib/discovery-missed.sh" "$DIR/bin/discovery-setup.sh" \
  "$DIR/catalog/prompts/discovery-daily.md" "$DIR/catalog/lanes.d/discovery-daily.json" 2>/dev/null || true)
check "D12 no claude-* literal [$HITS]" '[ -z "$HITS" ]'
check "D12 the route role is stage.discovery-daily" '[ "$(sort -u "$FXT/roles.log" 2>/dev/null)" = stage.discovery-daily ]'
reset; mkissue 112 9 | jq -s . > "$FXT/issues.json"; mkevent 112
run DISCOVERY_MAX_USD=0
check "D12 MAX_USD=0: no call, no row" '[ "$(calls)" = 0 ] && [ ! -e "$(lfile 112)" ]'

# ── D13: a lane-filed open ticket is never an item ───────────────────────────
reset; echo '[]' > "$FXT/issues.json"
jq -nc '[{number: 401, title: "Sentry 101: earlier", body: "x\n<!-- discovery: sentry/101 -->\n"}]' > "$FXT/open.json"
run
check "D13 read=0 and no call [$(summary)]" '[[ "$(summary)" == *" read=0 "* ]] && [ "$(calls)" = 0 ]'

# ── D14: the kill switch ─────────────────────────────────────────────────────
for fl in lane-off-discovery-daily all-off; do
  reset; mkissue 114 9 | jq -s . > "$FXT/issues.json"; mkevent 114
  mkdir -p "$H/flags"; touch "$H/flags/$fl"
  run
  check "D14 $fl: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
  check "D14 $fl: no curl" '[ ! -s "$FXT/curl.log" ]'
  check "D14 $fl: no ledger read" '[ ! -s "$FXT/ledger.log" ]'
  check "D14 $fl: no call" '[ ! -s "$FXT/ac.log" ]'
  rm -f "$H/flags/$fl"
done
# The ledger outage at the claim: one alert, no fetch.
reset; mkissue 124 9 | jq -s . > "$FXT/issues.json"; mkevent 124
echo 1 > "$FXT/ledger.rc"
run
check "D14 ledger outage: no curl, one ledger alert" '[ "$(curls)" = 0 ] && [ "$(grep -c discovery-daily-ledger "$FXT/alerts.log" 2>/dev/null)" = 1 ]'
# A project fleet.conf does not name: usage, rc 2.
reset
env HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 DISCOVERY_DAILY_FIXTURE="$T/fixture.sh" FLEET_CONF="$H/fleet.conf" \
  bash "$H/bin/discovery-daily.sh" no-such-project > "$T/out" 2>&1; RC14=$?
check "D14 an unknown project: rc 2, no read ($RC14)" '[ "$RC14" = 2 ] && [ ! -s "$FXT/ledger.log" ]'

# ── D15: the summary and its cost ────────────────────────────────────────────
reset; { mkissue 151 9; mkissue 152 1; } | jq -s . > "$FXT/issues.json"; mkevent 151
echo 0.25 > "$FXT/cost.usd"
run
check "D15 one Telegram send with the run akey" '[ "$(wc -l < "$FXT/tg.log" 2>/dev/null)" = 1 ] && [ "$(cut -f1 "$FXT/tg.log")" = "discovery-daily:$P:$DAY" ]'
TG=$(cut -f2 "$FXT/tg.log" 2>/dev/null)
check "D15 the text has the counts [$TG]" 'grep -q "read 2" <<<"$TG" && grep -q "dropped by code 1" <<<"$TG" && grep -q "model calls 1" <<<"$TG" && grep -q "tickets filed 1" <<<"$TG"'
check "D15 the cost is the cost.csv sum" 'grep -q "cost \$0.25" <<<"$TG" && [ "$(runrow | jq -r ".detail | fromjson | .usd")" = 0.25 ]'
reset; mkissue 153 9 | jq -s . > "$FXT/issues.json"; mkevent 153
: > "$FXT/cost.usd"
run
TG=$(cut -f2 "$FXT/tg.log" 2>/dev/null)
check "D15 a blank cost row: unpriced [$TG]" 'grep -q "cost unpriced" <<<"$TG" && [ "$(runrow | jq -r ".detail | fromjson | .usd")" = unpriced ]'

# ── D16: the decision table ──────────────────────────────────────────────────
decide() {
  bash -c '. "$1/bin/lib/discovery/rules.sh"; dd_rules_decide "$2" "$3"' _ "$DIR" "$1" "$2" 2>/dev/null
}
A() { # A <benign> <impact> <own> <same> [title]
  jq -nc --arg b "$1" --arg u "$2" --arg o "$3" --argjson s "$4" --arg t "${5-Save fails}" \
    '{answers: {known_benign: $b, user_impact: $u, own_code: $o, same_ticket: $s}, draft: {title: $t, cause: "c", proposed_fix: "f", acceptance_tests: ["T1"]}}'
}
row16() { local got want=$4; got=$(decide "$2" "$3"); check "D16 $1 -> $4 (got '$got')" '[ "$got" = "$want" ]'; }
row16 "ticket"                "$(A no yes yes 0)" '[]' ticket
row16 "impact unknown"        "$(A no unknown yes 0)" '[]' ticket
row16 "case and space"        "$(A 'No ' yes YES 0)" '[]' ticket
row16 "own no, impact yes"    "$(A no yes no 0)" '[]' ticket
row16 "same outside the list" "$(A no yes yes 7)" '[5]' ticket
row16 "benign"                "$(A yes yes yes 0)" '[]' "noise known-benign"
row16 "benign over comment"   "$(A yes yes yes 5)" '[5]' "noise known-benign"
row16 "own no, impact no"     "$(A no no no 0)" '[]' "noise not-own-code"
row16 "own no, impact unk"    "$(A no unknown no 0)" '[]' "noise not-own-code"
row16 "comment"               "$(A no yes yes 5)" '[5,9]' "comment 5"
row16 "comment, own no"       "$(A no no no 9)" '[5,9]' "comment 9"
row16 "answers missing"       '{"draft":{"title":"t","cause":"c"}}' '[]' invalid
row16 "same as a string"      "$(A no yes yes 0 | jq -c '.answers.same_ticket = "5"')" '[5]' invalid
row16 "title empty"           "$(A no yes yes 0 '')" '[]' invalid
row16 "benign maybe"          "$(A maybe yes yes 0)" '[]' invalid
row16 "a verdict key decides nothing" "$(A no yes yes 0 | jq -c '. + {verdict: "noise"}')" '[]' ticket

# ── D17: bin/discovery-setup.sh ──────────────────────────────────────────────
setup() {
  env HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 DISCOVERY_DAILY_FIXTURE="$T/fixture.sh" \
    FLEET_CONF="$H/fleet.conf" JOBS_URL= bash "$H/bin/discovery-setup.sh" "$@" > "$T/sout" 2>&1
  echo $? > "$T/src"
}
sets() { if [ -f "$FXT/ctl.log" ]; then grep -c '^set ' "$FXT/ctl.log"; else echo 0; fi; }
reset
setup --project "$P" --sources sentry --sentry-project project-6-web --repo example-org/project-6
check "D17 run 1: rc 0, 3 set calls ($(sets); $(head -c 200 "$T/sout"))" '[ "$(cat "$T/src")" = 0 ] && [ "$(sets)" = 3 ]'
check "D17 run 1: the set calls name the lane, knob and project" 'grep -qx "set discovery-daily DISCOVERY_SOURCES sentry $P" "$FXT/ctl.log" && grep -qx "set discovery-daily DISCOVERY_SENTRY_PROJ project-6-web $P" "$FXT/ctl.log" && grep -qx "set discovery-daily DISCOVERY_TARGET_REPO example-org/project-6 $P" "$FXT/ctl.log"'
setup --project "$P" --sources sentry --sentry-project project-6-web --repo example-org/project-6
check "D17 run 2: no set call, 3 unchanged lines ($(sets))" '[ "$(cat "$T/src")" = 0 ] && [ "$(sets)" = 3 ] && [ "$(grep -c "^unchanged " "$T/sout")" = 3 ]'
reset
setup --project "$P" --sources sentry
check "D17 no --repo: no target-repo write" '[ "$(cat "$T/src")" = 0 ] && [ "$(sets)" = 1 ] && ! grep -q TARGET_REPO "$FXT/ctl.log"'
for badargs in "--project no-such --sources sentry" "--project $P --sources intercom" \
               "--project $P --sources sentry --sentry-project Bad/Slug" "--project $P --sources sentry --repo not-a-repo" \
               "--project $P --sources sentry --repo example-org/not-in-fleet" "--project $P --sources sentry --repo ../x/y" \
               "--project $P --sources ../x" "--project $P --sources sentry;id"; do
  reset
  # shellcheck disable=SC2086
  setup $badargs
  check "D17 bad input '$badargs': non-zero, 0 calls" '[ "$(cat "$T/src")" != 0 ] && [ "$(sets)" = 0 ]'
done
reset; echo 1 > "$FXT/settings.rc"
setup --project "$P" --sources sentry
check "D17 settings unreadable: rc 1, nothing written" '[ "$(cat "$T/src")" = 1 ] && [ "$(sets)" = 0 ]'

# ── D18: the missed-run check ────────────────────────────────────────────────
YDAY=$(date -u -d "@$((NOW - 86400))" +%F)
missed() { # missed <sources> -> the alert count after the call (MNOW overrides NOW)
  env HARNESS="$H" FXT="$FXT" FLEET_CONF="$H/fleet.conf" SRC="$1" NOW="${MNOW:-$NOW}" JOBS_URL= bash -c '
    . "$HARNESS/bin/lib/lane-gate.sh"
    lane_knob() { [ "$3" = project-6-os ] && printf "%s" "$SRC"; return 0; }
    alert() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$FXT/ph-alerts.log"; }
    # BH-9820: as pipeline-health'"'"'s alert_digest: every call is fired (ph-fired.log),
    # the TTL dedupe lets only the first call per key beat (ph-alerts.log).
    alert_digest() { printf "%s\n" "$2" >> "$FXT/ph-fired.log"
      grep -qF " $2 " "$FXT/ph-alerts.log" 2>/dev/null || printf "%s %s %s\n" "$1" "$2" "$3" >> "$FXT/ph-alerts.log"; }
    . "$HARNESS/bin/lib/discovery-missed.sh"; . "$FXT/../fixture.sh"
    dd_missed_check "$NOW"' 2>/dev/null
  if [ -f "$FXT/ph-alerts.log" ]; then wc -l < "$FXT/ph-alerts.log"; else echo 0; fi
}
sincerow() { jq -nc --arg s "$1" '{status: "active", detail: ({since: $s} | tojson)}' > "$FXT/ledger/discovery-daily-since.$P"; }
reset; sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"
check "D18 missed: exactly 1 alert" '[ "$(missed sentry)" = 1 ]'
# TEST-CHANGE (BH-9820 item 4): the TTL was the literal 86400; the key holds the
# day, so the dedupe window is now the marker retention DISCOVERY_MARKER_KEEP_D
# (default 30 d = 2592000 s). The key assertion is unchanged.
check "D18 the alert key names the project and day" 'grep -q "^2592000 discovery-missed:$P:$YDAY " "$FXT/ph-alerts.log"'
check "D18 a second tick the same day: still 1" '[ "$(missed sentry)" = 1 ]'
reset; sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"
jq -nc '{status: "done", detail: "{}"}' > "$FXT/ledger/discovery-daily-run.$P+$YDAY"
check "D18 a done row: 0 alerts" '[ "$(missed sentry)" = 0 ]'
reset; jq -nc '{status: "running", detail: "{}"}' > "$FXT/ledger/discovery-daily-run.$P+$YDAY"
sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"
check "D18 a running row from yesterday: 1 alert" '[ "$(missed sentry)" = 1 ]'
reset; sincerow "$DAY"
check "D18 since today: 0 alerts" '[ "$(missed sentry)" = 0 ]'
reset
check "D18 no since row: 0 alerts" '[ "$(missed sentry)" = 0 ]'
reset; sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"
check "D18 DISCOVERY_SOURCES empty: 0 alerts" '[ "$(missed "")" = 0 ]'
reset; sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"; mkdir -p "$H/flags"; touch "$H/flags/lane-off-discovery-daily"
check "D18 lane off: 0 alerts" '[ "$(missed sentry)" = 0 ]'
check "D18 lane off: no ledger read" '[ ! -s "$FXT/ledger.log" ]'
scratch_rm "$H/flags/lane-off-discovery-daily"
reset; sincerow "$(date -u -d "@$((NOW - 3 * 86400))" +%F)"; mkdir -p "$H/flags"; touch "$H/flags/lane-off-discovery-daily-$P"
check "D18 project paused on the lane: 0 alerts" '[ "$(missed sentry)" = 0 ]'
scratch_rm "$H/flags/lane-off-discovery-daily-$P"

# ── N1: the detail, candidate-match and title cuts are knobs ─────────────────
longevent() { # longevent <id>: an event whose message is 1200 a's, then ZZTAIL
  mkevent "$1"
  jq --arg m "$(printf 'a%.0s' $(seq 1 1200))ZZTAIL" '.message = $m' "$FXT/event-$1.json" > "$FXT/e.tmp" && mv "$FXT/e.tmp" "$FXT/event-$1.json"
}
reset; mkissue 161 9 | jq -s . > "$FXT/issues.json"; longevent 161
run
check "N1 detail default 12000: the tail past 1200 bytes is in the prompt" 'grep -q ZZTAIL "$FXT/prompt.last"'
reset; mkissue 161 9 | jq -s . > "$FXT/issues.json"; longevent 161
run DISCOVERY_DETAIL_MAX_BYTES=1000
check "N1 DETAIL_MAX_BYTES=1000: the detail is cut before the tail" '[ -s "$FXT/prompt.last" ] && grep -q aaaaaaaaaa "$FXT/prompt.last" && ! grep -q ZZTAIL "$FXT/prompt.last"'
reset; mkissue 161 9 | jq -s . > "$FXT/issues.json"; longevent 161
run DISCOVERY_DETAIL_MAX_BYTES=5
check "N1 DETAIL_MAX_BYTES=5 is out of range: one warn line and the default" 'grep -q "DISCOVERY_DETAIL_MAX_BYTES=5 is outside 1000..100000" "$LOG" && grep -q ZZTAIL "$FXT/prompt.last"'
candrun() { # candrun [VAR=value...]: one item whose title starts like open ticket #501
  reset; mkissue 162 9 | jq -c '.title = "Payment webhook rejects a signed request from the provider"' | jq -s . > "$FXT/issues.json"; mkevent 162
  jq -nc '[{number: 501, title: "Payment webhook reje is another problem", body: "b"}]' > "$FXT/open.json"
  run "$@"
}
candrun
check "N1 candidate match default 60 chars: no candidate" '[ -s "$FXT/prompt.last" ] && grep -A1 -x "## Candidate open tickets" "$FXT/prompt.last" | grep -qx none && ! grep -q "#501 " "$FXT/prompt.last"'
candrun DISCOVERY_CAND_MATCH_CHARS=20
check "N1 CAND_MATCH_CHARS=20: #501 is a candidate" 'grep -q "#501 Payment webhook reje" "$FXT/prompt.last"'
LONGT=$(printf 'T%.0s' $(seq 1 100))
reset; mkissue 165 9 | jq -c --arg t "$LONGT" '.title = $t' | jq -s . > "$FXT/issues.json"; mkevent 165
run
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "N1 title defaults: item title 100 kept, ticket title not cut ($(ldet 165 '.title | length'))" '[ "$(ldet 165 ".title | length")" = 100 ] && [ "$(jq -r .title <<<"$PAY" 2>/dev/null)" = "Sentry 165: Checkout save fails - on a null cart" ]'
reset; mkissue 165 9 | jq -c --arg t "$LONGT" '.title = $t' | jq -s . > "$FXT/issues.json"; mkevent 165
run DISCOVERY_ITEM_TITLE_CHARS=40 DISCOVERY_TICKET_TITLE_CHARS=40
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "N1 ITEM_TITLE_CHARS=40: the row title is 40 chars ($(ldet 165 '.title | length'))" '[ "$(ldet 165 ".title | length")" = 40 ]'
check "N1 TICKET_TITLE_CHARS=40: the ticket title is cut to 40 ($(jq -r .title <<<"$PAY" 2>/dev/null))" '[ "$(jq -r .title <<<"$PAY" 2>/dev/null)" = "Sentry 165: Checkout save fails - on a n" ]'
# The adapter must not cut before the knob does (lead review of e8df5e8c): a
# 450-char title stays 450 with the knob at 500, and is 300 at the default.
LONGT450=$(printf 'T%.0s' $(seq 1 450))
reset; mkissue 165 9 | jq -c --arg t "$LONGT450" '.title = $t' | jq -s . > "$FXT/issues.json"; mkevent 165
run DISCOVERY_ITEM_TITLE_CHARS=500
check "N1 ITEM_TITLE_CHARS=500: a 450-char title stays 450 ($(ldet 165 '.title | length'))" '[ "$(ldet 165 ".title | length")" = 450 ]'
reset; mkissue 165 9 | jq -c --arg t "$LONGT450" '.title = $t' | jq -s . > "$FXT/issues.json"; mkevent 165
run
check "N1 ITEM_TITLE_CHARS default: a 450-char title is cut to 300 ($(ldet 165 '.title | length'))" '[ "$(ldet 165 ".title | length")" = 300 ]'

# ── N2: the missed-run marker retention is a knob ────────────────────────────
missed_keep() { # missed_keep <DISCOVERY_MARKER_KEEP_D as lane_knob prints it>
  env HARNESS="$H" FXT="$FXT" FLEET_CONF="$H/fleet.conf" KEEP="$1" NOW="$NOW" JOBS_URL= bash -c '
    . "$HARNESS/bin/lib/lane-gate.sh"
    lane_knob() { [ "$2" = DISCOVERY_MARKER_KEEP_D ] && printf "%s" "$KEEP"; return 0; }
    alert() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$FXT/ph-alerts.log"; }
    alert_digest() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$FXT/ph-alerts.log"; }
    . "$HARNESS/bin/lib/discovery-missed.sh"; . "$FXT/../fixture.sh"
    dd_missed_check "$NOW"' 2>/dev/null
}
MD="$H/state/discovery-daily"; MK="$MD/missed-ok-other-os-2026-01-01"
oldmarker() { mkdir -p "$MD"; touch -d "@$(( $(date +%s) - 10 * 86400 ))" "$MK"; }
reset; oldmarker; missed_keep ""
check "N2 knob empty: the 30-day fallback keeps a 10-day marker" '[ -e "$MK" ]'
missed_keep 5
check "N2 MARKER_KEEP_D=5: a 10-day marker is deleted" '[ ! -e "$MK" ]'
reset; oldmarker; scratch_rm "$H/logs/pipeline-health.log"; missed_keep 0
check "N2 MARKER_KEEP_D=0 is out of range: one warn line, the marker stays" '[ -e "$MK" ] && [ "$(grep -c "DISCOVERY_MARKER_KEEP_D=0 is outside 1..365" "$H/logs/pipeline-health.log" 2>/dev/null)" = 1 ]'
check "N2 no alert from the retention runs" '[ ! -e "$FXT/ph-alerts.log" ]'

# ── N3: calls with no cost row: usd unknown, not 0 ───────────────────────────
reset; mkissue 171 9 | jq -s . > "$FXT/issues.json"; mkevent 171
run
TG=$(cut -f2 "$FXT/tg.log" 2>/dev/null)
check "N3 one call, no cost row: Telegram says cost unknown [$TG]" '[ "$(calls)" = 1 ] && grep -q "cost unknown\." <<<"$TG" && ! grep -q "\$unknown" <<<"$TG"'
check "N3 run row usd unknown" '[ "$(runrow | jq -r ".detail | fromjson | .usd")" = unknown ]'
check "N3 summary usd=unknown [$(summary)]" '[[ "$(summary)" == *" usd=unknown "* ]]'
reset; mkissue 172 1 | jq -s . > "$FXT/issues.json"
run
TG=$(cut -f2 "$FXT/tg.log" 2>/dev/null)
check "N3 no call, no cost row: usd 0 [$TG]" '[ "$(calls)" = 0 ] && grep -q "cost \$0\.$" <<<"$TG" && [ "$(runrow | jq -r ".detail | fromjson | .usd")" = 0 ]'

# ── N4: a retry row past the attempts: failed and one failed alert ───────────
reset; mkissue 181 9 | jq -s . > "$FXT/issues.json"; mkevent 181
jq -nc '{status: "retry", detail: ({source: "sentry", id: "181", attempts: 3, last_rc: 1} | tojson)}' > "$(lfile 181)"
run
check "N4 retry at attempts 3: failed {why: attempts}, no call ($(lstat 181)/$(calls))" '[ "$(lstat 181)" = failed ] && [ "$(ldet 181 .why)" = attempts ] && [ "$(calls)" = 0 ]'
check "N4 exactly one failed alert" '[ "$(grep -c "discovery-daily-failed" "$FXT/alerts.log" 2>/dev/null)" = 1 ]'
RUN_NOW=$((NOW + 86400)) run
check "N4 the next run: no call, still one alert" '[ "$(calls)" = 0 ] && [ "$(grep -c "discovery-daily-failed" "$FXT/alerts.log")" = 1 ]'

# ── S1: DISCOVERY_SOURCES is checked before any file is loaded ──────────────
# Planted files that a bad value would load if it reached `.`: each one touches
# $FXT/loaded.
plant() { mkdir -p "$(dirname "$1")"; printf 'touch "$FXT/loaded"\n' > "$1"; }
plant "$H/bin/lib/x.sh"; plant "$H/bin/lib/discovery/sentry;id.sh"; plant "$H/bin/lib/discovery/x.sh"
for v in '../x' 'sentry;id' 'sentry,../x' 'x/../x' 'sentry id;x'; do
  reset; mkissue 191 9 | jq -s . > "$FXT/issues.json"; mkevent 191
  run DISCOVERY_SOURCES="$v"
  check "S1 '$v': rc 0, no file loaded, no fetch, no call" '[ "$(cat "$T/rc")" = 0 ] && [ ! -e "$FXT/loaded" ] && [ "$(curls)" = 0 ] && [ "$(calls)" = 0 ]'
  check "S1 '$v': one refusal line, the value not logged" '[ "$(grep -c "DISCOVERY_SOURCES is not" "$LOG")" = 1 ] && ! grep -qF "$v" "$LOG"'
done
reset; mkissue 192 9 | jq -s . > "$FXT/issues.json"; mkevent 192
run DISCOVERY_SOURCES='nosuch, sentry'
check "S1 an unknown name is logged and skipped; sentry still runs" 'grep -q "source .nosuch. has no adapter" "$LOG" && [ "$(calls)" = 1 ] && [ ! -e "$FXT/loaded" ]'
scratch_rm "$H/bin/lib/x.sh"; scratch_rm "$H/bin/lib/discovery/sentry;id.sh"; scratch_rm "$H/bin/lib/discovery/x.sh"

# ── T1: DISCOVERY_TARGET_REPO ────────────────────────────────────────────────
reset; mkissue 193 9 | jq -s . > "$FXT/issues.json"; mkevent 193
run DISCOVERY_TARGET_REPO=example-org/other-os
check "T1 a fleet.conf repo is the target: one create there" '[ "$(cat "$T/rc")" = 0 ] && [ "$(grep -c "^POST repos/example-org/other-os/issues " "$FXT/gh.log" 2>/dev/null)" = 1 ] && ! grep -q "^POST repos/example-org/project-6/issues " "$FXT/gh.log"'
for v in 'example-org/not-in-fleet' 'not-a-repo' '../x/y' 'example-org/project-6;id'; do
  reset; mkissue 194 9 | jq -s . > "$FXT/issues.json"; mkevent 194
  run DISCOVERY_TARGET_REPO="$v"
  check "T1 '$v': rc 0, no fetch, no call, no create" '[ "$(cat "$T/rc")" = 0 ] && [ "$(curls)" = 0 ] && [ "$(calls)" = 0 ] && [ "$(creates)" = 0 ]'
  check "T1 '$v': one no-target line, the value not logged" '[ "$(grep -c "no target repo" "$LOG")" = 1 ] && ! grep -qF "$v" "$LOG"'
done

# ── M1: model text cannot plant a marker (BH-9820 item 1) ───────────────────
# The cause, the fix and a test each carry a marker of item 999: plain, nested
# (a single strip would rebuild it) and with en/em dashes (_st_dash would make
# them "--").
answer_planted() {
  jq -nc '{answers: {known_benign: "no", user_impact: "yes", own_code: "yes", same_ticket: 0},
    draft: {title: "Save fails",
      cause: "The save fails. <!-- discovery: sentry/999 --> then <!<!---- discovery: sentry/999 ---->> then <!—- discovery: sentry/999 —–>",
      proposed_fix: "Guard it --> then <!-- more",
      acceptance_tests: ["T1: <!-- discovery: sentry/999 --> saves."]}}' > "$FXT/answer.txt"
}
reset; mkissue 195 9 | jq -s . > "$FXT/issues.json"; mkevent 195; answer_planted
run
BM=$(lastbody)
check "M1 the body has one <!--, its own marker" '[ -n "$BM" ] && [ "$(grep -o "<!--" <<<"$BM" | wc -l)" = 1 ] && grep -qxF "<!-- discovery: sentry/195 -->" <<<"$BM"'
check "M1 the body has no --> other than the end of its own marker" '[ -n "$BM" ] && [ "$(grep -o -- "-->" <<<"$BM" | wc -l)" = 1 ]'
check "M1 the body has no marker of item 999" '[ -n "$BM" ] && ! grep -qF "<!-- discovery: sentry/999 -->" <<<"$BM"'
# The next run: the filed issue is open and item 999 comes in.
jq -nc --arg b "$BM" '[{number: 9001, title: "Sentry 195: Save fails", body: $b}]' > "$FXT/open.json"
mkissue 999 9 | jq -s . > "$FXT/issues.json"; mkevent 999; answer_noise
RUN_NOW=$((NOW + 86400)) run
check "M1 the next run: item 999 is not ticketed ($(lstat 999)/$(ldet 999 .action))" '[ -n "$(lstat 999)" ] && [ "$(lstat 999)" != ticketed ]'
# The comment path.
reset; mkissue 196 9 | jq -c '.title = "Payment webhook rejects a signed request"' | jq -s . > "$FXT/issues.json"; mkevent 196
jq -nc '[{number: 502, title: "Payment webhook rejects a signed request", body: "b"}]' > "$FXT/open.json"
answer_planted; jq -c '.answers.same_ticket = 502' "$FXT/answer.txt" > "$FXT/a.tmp" && mv "$FXT/a.tmp" "$FXT/answer.txt"
run
CBM=$(grep '^COMMENT ' "$FXT/gh.log" 2>/dev/null | tail -n 1 | cut -d' ' -f4- | jq -r . 2>/dev/null)
check "M1 the comment has one <!-- and one -->, its own marker" '[ -n "$CBM" ] && [ "$(grep -o "<!--" <<<"$CBM" | wc -l)" = 1 ] && [ "$(grep -o -- "-->" <<<"$CBM" | wc -l)" = 1 ] && grep -qxF "<!-- discovery: sentry/196 -->" <<<"$CBM"'

# ── M2: bin/discovery-setup.sh writes the since row once (BH-9820 item 2) ────
sincev() { jq -r ".detail | fromjson | .since" "$FXT/ledger/discovery-daily-since.$P" 2>/dev/null; }
sinceputs() { if [ -f "$FXT/ledger.log" ]; then grep -c "^put discovery-daily-since " "$FXT/ledger.log"; else echo 0; fi; }
reset
DISCOVERY_DAILY_NOW=$NOW setup --project "$P" --sources sentry
check "M2 no since row: setup writes it with the setup date ($(sincev); $(head -c 200 "$T/sout"))" '[ "$(cat "$T/src")" = 0 ] && [ "$(sincev)" = "$DAY" ] && [ "$(sinceputs)" = 1 ]'
DISCOVERY_DAILY_NOW=$((NOW + 86400)) setup --project "$P" --sources sentry
check "M2 a second setup does not change the row ($(sincev), puts $(sinceputs))" '[ "$(cat "$T/src")" = 0 ] && [ "$(sincev)" = "$DAY" ] && [ "$(sinceputs)" = 1 ]'
reset; echo 1 > "$FXT/ledger.rc"
DISCOVERY_DAILY_NOW=$NOW setup --project "$P" --sources sentry
check "M2 the since row is unreadable: rc 1, nothing written" '[ "$(cat "$T/src")" = 1 ] && [ "$(sets)" = 0 ] && [ "$(sinceputs)" = 0 ]'

# ── M3: the missed-run alert (BH-9820 items 4, 5) ────────────────────────────
firedn() { if [ -f "$FXT/ph-fired.log" ]; then grep -cx "discovery-missed:$P:$1" "$FXT/ph-fired.log"; else echo 0; fi; }
reset; sincerow "$(date -u -d "@$((NOW - 2 * 86400))" +%F)"
check "M3 a since row from 2 days before and no run row: 1 alert" '[ "$(missed sentry)" = 1 ]'
check "M3 the alert went through alert_digest, TTL the marker retention" '[ "$(firedn "$YDAY")" = 1 ] && grep -q "^2592000 discovery-missed:$P:$YDAY " "$FXT/ph-alerts.log"'
MNOW=$((NOW + 3600)) missed sentry >/dev/null
check "M3 a later tick, no done row: the alert is fired again (held open), no second beat" '[ "$(firedn "$YDAY")" = 2 ] && [ "$(wc -l < "$FXT/ph-alerts.log")" = 1 ]'
echo 1 > "$FXT/ledger.rc"; MNOW=$((NOW + 7200)) missed sentry >/dev/null; rm -f "$FXT/ledger.rc"
check "M3 a ledger outage holds the alert open" '[ "$(firedn "$YDAY")" = 3 ]'
# Day D = YDAY. A done run row for D+1 (today): the next tick does not fire D.
jq -nc '{status: "done", detail: "{}"}' > "$FXT/ledger/discovery-daily-run.$P+$DAY"
MNOW=$((NOW + 10800)) missed sentry >/dev/null
check "M3 a done run row for D+1 (today): the alert of D is not fired again" '[ "$(firedn "$YDAY")" = 3 ] && [ "$(wc -l < "$FXT/ph-alerts.log")" = 1 ]'
MNOW=$((NOW + 86400)) missed sentry >/dev/null
check "M3 the next day: D stays closed, D+1 raises nothing" '[ "$(firedn "$YDAY")" = 3 ] && [ "$(firedn "$DAY")" = 0 ] && [ "$(wc -l < "$FXT/ph-alerts.log")" = 1 ]'
# D+1 = yesterday: a missed day two ticks back closes once yesterday is done.
reset; sincerow "$(date -u -d "@$((NOW - 5 * 86400))" +%F)"
D2=$(date -u -d "@$((NOW - 2 * 86400))" +%F)
MNOW=$((NOW - 86400)) missed sentry >/dev/null
check "M3 the missed day D is alerted and fired" '[ "$(firedn "$D2")" = 1 ]'
jq -nc '{status: "done", detail: "{}"}' > "$FXT/ledger/discovery-daily-run.$P+$YDAY"
: > "$FXT/ph-fired.log"; missed sentry >/dev/null
check "M3 a done run row for D+1 (yesterday): the alert of D is not fired" '[ "$(grep -c "discovery-missed:$P:$D2 " "$FXT/ph-alerts.log")" = 1 ] && [ "$(firedn "$D2")" = 0 ] && [ "$(firedn "$YDAY")" = 0 ]'
check "M3 discovery-missed is in RETRACT_NS" 'grep -qE "^RETRACT_NS=\"([a-z|]*\|)?discovery-missed(\||\")" "$DIR/bin/pipeline-health.sh"'
check "M3 the check calls alert_digest, never alert" 'grep -q "alert_digest " "$DIR/bin/lib/discovery-missed.sh" && ! grep -qE "^[[:space:]]*alert [0-9]" "$DIR/bin/lib/discovery-missed.sh"'

# ── M4: the project env file (BH-9820 item 6) ────────────────────────────────
authok() { [ -s "$FXT/auth.log" ] && [ -z "$(grep -vxF -- "$1" "$FXT/auth.log")" ]; }
reset; printf 'SENTRY_API_TOKEN=tok-fixture-global-A\n' > "$H/env/global.env"
printf '%s\n' '# the project token' 'DISCOVERY_SENTRY_TOKEN="tok-fixture-proj-B"' > "$H/env/$P.env"
mkissue 197 9 | jq -s . > "$FXT/issues.json"; mkevent 197
run GH_TOKEN=tok-fixture-gh-orig
check "M4 global A, project B: every Sentry call is Bearer tok-fixture-proj-B [$(sort -u "$FXT/auth.log" 2>/dev/null | head -3 | tr '\n' ' ')]" 'authok "Bearer tok-fixture-proj-B GH_TOKEN=tok-fixture-gh-orig"'
reset; mkissue 198 9 | jq -s . > "$FXT/issues.json"; mkevent 198
P=other-os; run GH_TOKEN=tok-fixture-gh-orig; P=project-6-os
check "M4 a project with no project file: Bearer tok-fixture-global-A" 'authok "Bearer tok-fixture-global-A GH_TOKEN=tok-fixture-gh-orig"'
reset; mkissue 199 9 | jq -s . > "$FXT/issues.json"; mkevent 199
printf '%s\n' 'GH_TOKEN=tok-fixture-gh-X' 'SENTRY_API_TOKEN=tok-fixture-proj-Z' 'touch "$FXT/sourced"' 'export DISCOVERY_SENTRY_ORG=evil-org' > "$H/env/$P.env"
run GH_TOKEN=tok-fixture-gh-orig
check "M4 other names in the project file change nothing" 'authok "Bearer tok-fixture-global-A GH_TOKEN=tok-fixture-gh-orig" && [ ! -e "$FXT/sourced" ] && ! grep -q evil-org "$FXT/curl.log"'
reset; mkissue 200 9 | jq -s . > "$FXT/issues.json"; mkevent 200
printf '%s\n' "export DISCOVERY_SENTRY_TOKEN='tok-fixture-proj-C'" > "$H/env/$P.env"
run GH_TOKEN=tok-fixture-gh-orig
check "M4 export and single quotes: Bearer tok-fixture-proj-C" 'authok "Bearer tok-fixture-proj-C GH_TOKEN=tok-fixture-gh-orig"'
reset; mkissue 200 9 | jq -s . > "$FXT/issues.json"; mkevent 200
printf '%s\n' 'DISCOVERY_SENTRY_TOKEN=$(touch "$FXT/sourced")' > "$H/env/$P.env"
run GH_TOKEN=tok-fixture-gh-orig
check "M4 a value is never run" '[ ! -e "$FXT/sourced" ]'
check "M4 no project or global token in the log" '! grep -qE "tok-fixture-proj-[A-Z]|tok-fixture-global-A" "$LOG"'
: > "$H/env/global.env"; scratch_rm "$H/env/$P.env"

# ── M5: bin/discovery-setup.sh --sentry-org (BH-9820 item 6) ─────────────────
orgsets() { if [ -f "$FXT/ctl.log" ]; then grep -cx "set discovery-daily DISCOVERY_SENTRY_ORG project-6-llc $P" "$FXT/ctl.log"; else echo 0; fi; }
reset
setup --project "$P" --sources sentry --sentry-org project-6-llc
check "M5 --sentry-org writes the org row ($(orgsets); $(head -c 200 "$T/sout"))" '[ "$(cat "$T/src")" = 0 ] && [ "$(orgsets)" = 1 ]'
setup --project "$P" --sources sentry --sentry-org project-6-llc
check "M5 a second run: the org row is written once" '[ "$(cat "$T/src")" = 0 ] && [ "$(orgsets)" = 1 ] && grep -q "^unchanged lane.discovery-daily.$P.discovery_sentry_org=project-6-llc$" "$T/sout"'
for v in '../x' 'Bad/Org' 'org;id'; do
  reset; setup --project "$P" --sources sentry --sentry-org "$v"
  check "M5 --sentry-org '$v': rc 2, nothing written" '[ "$(cat "$T/src")" = 2 ] && [ "$(sets)" = 0 ] && [ "$(sinceputs)" = 0 ]'
done

# ── M6: a 401/403/404 list answer (BH-9820 item 6) ───────────────────────────
for code in 401 403 404; do
  reset; echo "$code" > "$FXT/list.code"; printf 'DISCOVERY_SENTRY_TOKEN=tok-fixture-proj-B\n' > "$H/env/$P.env"
  run DISCOVERY_SENTRY_ORG=project-6-llc
  check "M6 HTTP $code: one log line names the org and the slug [$(grep -c project-6-llc "$LOG" 2>/dev/null)]" '[ "$(grep project-6-llc "$LOG" 2>/dev/null | grep -c project-6-web)" = 1 ]'
  check "M6 HTTP $code: no token in the log or the alerts" '! grep -qE "tok-fixture-proj-B|tok-fixture-1" "$LOG" "$FXT/alerts.log" 2>/dev/null'
done
scratch_rm "$H/env/$P.env"

# ── M7: the run-claim stale pad is a knob (BH-9820 item 4) ───────────────────
reset; echo '[]' > "$FXT/issues.json"
run
check "M7 default: stale after 1500 + 60 s" 'grep -qx "claim discovery-daily-run $P/$DAY running 1560" "$FXT/ledger.log"'
reset; echo '[]' > "$FXT/issues.json"
run DISCOVERY_STALE_PAD_S=120
check "M7 DISCOVERY_STALE_PAD_S=120: stale after 1620 s" 'grep -qx "claim discovery-daily-run $P/$DAY running 1620" "$FXT/ledger.log"'
reset; echo '[]' > "$FXT/issues.json"
run DISCOVERY_STALE_PAD_S=99999
check "M7 out of range: one warn line and the default" 'grep -q "DISCOVERY_STALE_PAD_S=99999 is outside" "$LOG" && grep -qx "claim discovery-daily-run $P/$DAY running 1560" "$FXT/ledger.log"'

# ── D19: the composed schema ─────────────────────────────────────────────────
SQL="$T/schema.sql"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bash bin/schema-build.sh --to "$SQL" ) > "$T/sb.out" 2>&1
check "D19 the schema composes ($(head -c 200 "$T/sb.out"))" '[ -s "$SQL" ]'
check "D19 the project-6-os sources row" 'grep -q "lane.discovery-daily.project-6-os.discovery_sources[^,]*, *.sentry." "$SQL"'
check "D19 no target-repo row (tickets go to the fleet.conf repo)" '! grep -q "discovery_target_repo" "$SQL"'
check "D19 no sentry-project row" '! grep -q "discovery_sentry_proj" "$SQL"'
check "D19 the stage.discovery-daily route insert" 'grep -q "stage.discovery-daily" "$SQL"'
check "D19 the two new fragments hold no CREATE TABLE" '! grep -qi "create table" "$DIR"/worker/jobs/schema.d/*-bh-9795-*.sql'

# ── R: the registry knobs ────────────────────────────────────────────────────
REG=$(jq -c '[.knobs[] | {(.env): .default}] | add' "$DIR/catalog/lanes.d/discovery-daily.json" 2>/dev/null)
check "R the 7 numeric ticket knobs [$REG]" \
  '[ "$(jq -c "[.DISCOVERY_MIN_EVENTS, .DISCOVERY_LOOKBACK_H, .DISCOVERY_TICKETS_DAY, .DISCOVERY_MAX_CALLS_DAY, .DISCOVERY_MAX_USD, .DISCOVERY_MAX_ATTEMPTS, .DISCOVERY_HOTFIX_24H]" <<<"$REG" 2>/dev/null)" = "[3,24,5,10,0.5,3,50]" ]'
check "R the cut and retention knobs" \
  '[ "$(jq -c "[.DISCOVERY_DETAIL_MAX_BYTES, .DISCOVERY_CAND_MATCH_CHARS, .DISCOVERY_TICKET_TITLE_CHARS, .DISCOVERY_ITEM_TITLE_CHARS, .DISCOVERY_MARKER_KEEP_D]" <<<"$REG" 2>/dev/null)" = "[12000,60,120,300,30]" ]'
check "R the identity knobs" '[ "$(jq -c "[.DISCOVERY_SOURCES, .DISCOVERY_SENTRY_ORG, .DISCOVERY_SENTRY_PROJ, .DISCOVERY_TARGET_REPO]" <<<"$REG" 2>/dev/null)" = "[\"\",\"operator\",\"\",\"\"]" ]'
check "R the target-repo knob is settable per project" '[ "$(jq -c ".knobs[] | select(.env == \"DISCOVERY_TARGET_REPO\") | [.settable, (.project_scoped // true)]" "$DIR/catalog/lanes.d/discovery-daily.json")" = "[true,true]" ]'
check "R every per-project settings key fits 64 chars with the longest fleet slug" \
  'L=$(awk "NF && \$1 !~ /^#/ {print length(\$1)}" "$DIR/fleet.conf" | sort -n | tail -1); [ -n "$L" ] && [ -z "$(jq -r --argjson l "$L" ".knobs[] | select(.settable != false) | select(.project_scoped != false) | .env | ascii_downcase | select((21 + \$l + 1 + length) > 64)" "$DIR/catalog/lanes.d/discovery-daily.json")" ]'
check "R the seams are settable:false" '[ "$(jq -c "[.knobs[] | select(.env | IN(\"DISCOVERY_DAILY_NOW\",\"DISCOVERY_DAILY_FIXTURE\",\"HARNESS_TEST_SANDBOX\")) | .settable] | unique" "$DIR/catalog/lanes.d/discovery-daily.json")" = "[false]" ]'
check "R the stale pad knob (BH-9820)" '[ "$(jq -c "[.env, .default, .min, .max, .settable]" "$DIR/catalog/lanes.d/discovery-daily.knobs.d/DISCOVERY_STALE_PAD_S.json")" = "[\"DISCOVERY_STALE_PAD_S\",60,0,600,true]" ]'
check "R DISCOVERY_SENTRY_TOKEN is a secret, not a knob (BH-9820)" '! jq -e ".knobs[] | select(.env == \"DISCOVERY_SENTRY_TOKEN\")" "$DIR/catalog/lanes.d/discovery-daily.json" >/dev/null && grep -qx "#DISCOVERY_SENTRY_TOKEN=" "$DIR/env-templates/lanes/386-discovery-daily.env.example"'
check "R scope project, hub box" '[ "$(jq -c "[.scope, .boxes]" "$DIR/catalog/lanes.d/discovery-daily.json")" = "[\"project\",[\"hub\"]]" ]'

echo "discovery-daily: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
