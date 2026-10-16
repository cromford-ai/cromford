#!/bin/bash
# tests/gh-budget-report.bh-6974-test.sh — BH-6974 (wave 1 of #6545): who
# spends the GitHub budget. bin/gh-budget-report.sh and its block in
# bin/dora-digest.sh, driven over real curl against the REAL jobs worker
# (tests/lib/gh-budget-worker.bh-6974.mjs, worker clock pinned to NOW).
#
#   B1  12 (lane, class) pairs on 2 boxes and 3 hours, --merged 4: the top 10
#       in rank order (counted, then calls, then name), totals, per-PR numbers
#   B1b no --merged: the merge count is GET /api/metrics/dora's (3 in 24 h)
#   B2  a lane with rows only outside the window, and a GraphQL-only lane, are
#       absent (never 0); the GraphQL calls are in totals.graphql_calls
#   B3  the digest carries the block: gh_budget.top[0] and per_merged_pr equal
#       the report file's, one `github REST:` line, one dora read
#   B3b DORA_GH_BUDGET=0: status off, no line, no gh-ledger read
#   B3c a report that exits 7: digest rc 0, status error, `n/a (error)`, one
#       log line naming rc 7, no ALERTS line
#   B4  --merged 0: per-PR null, "no merges in window"
#   B5  --window 7d / 24h file names; --window 3x is rc 2 and writes nothing
#   B6  --local: this box's hour files, the REST/GraphQL and repo tables, the
#       file outside the window not counted
#   F1  worker unreachable: local read, the first line says so, rc 0
#   F2  a worker with no `group` echo: local read, reason "no group echo"
#   F3  --merged x: rc 2, usage, no file
#   W1  the state dir cannot be created: the text still prints, rc 3
#   R1  state/gh-budget/ retention: 90 days by default, the env knob and the
#       settings row override it, a bad value falls back to 90 and says so
#
# Run from anywhere: tests/gh-budget-report.bh-6974-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 120 || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/gh-budget-worker.bh-6974.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
# same, and an empty side never passes: two missing values are not equal values
eqn() { if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or python3 missing"; exit 0; }
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags"
for L in bin/gh-budget-report.sh bin/dora-digest.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
# The digest runs its python by path; no shell `.` names it, so the closure does not.
cp "$REPO/bin/dora-digest.py" "$H/bin/dora-digest.py"
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -x "$REPO/bin/gh-budget-report.sh" ] && ok "bin/gh-budget-report.sh is executable in the repo" || bad "bin/gh-budget-report.sh is not executable"
[ -x "$H/bin/gh-budget-report.sh" ] && ok "closure installs bin/gh-budget-report.sh" || bad "closure lacks bin/gh-budget-report.sh"

# ONE clock read. The worker, the report (GH_BUDGET_NOW) and every fixture hour
# below are offsets from it.
NOW=$(date -u +%s)
hr()  { date -u -d "@$((NOW - $1 * 3600))" +%Y-%m-%dT%H; }
iso() { date -u -d "@$((NOW - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }
TODAY=$(date -u -d "@$NOW" +%F)
CUR=$(hr 0); MID=$(hr 5); SINCE=$(hr 24); BEFORE=$(hr 25); OLD=$(hr 48)

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub GH_BUDGET_NOW=$NOW
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
printf 'HARNESS_SECRET=fixture-harness-secret\n' > "$H/env/global.env"

: > "$T/w.log"
node "$SRV" "$T/w.log" "$NOW" > "$T/w.port" 2> "$T/w.err" &
WPID=$!
trap 'kill $WPID 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port" 2>/dev/null)
if [ -z "$PORT" ]; then
  wait "$WPID"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")" >/dev/null; }
# led <box> <hour> <lane> <resource> <path_class> <calls> <counted>
led() { sql "INSERT INTO gh_ledger (box,hour,lane,project,meter,resource,method,path_class,status,source,calls,counted,updated_at) VALUES (?,?,?,'-','app-1',?,'GET',?,'200','rest',?,?,'2026-10-15T00:00:00Z')" "$@"; }
report() { bash "$H/bin/gh-budget-report.sh" "$@"; }
SF="$H/state/gh-budget/$TODAY.json"

# ---- the fixture: 12 (lane, class) pairs --------------------------------------
# lane|class|counted|calls. Every pair is split over three rows: 10/10 on the
# hub at SINCE (the boundary hour, inside), 10/10 on pool-1 at MID, the rest on
# the hub at CUR. lane-g and lane-h tie on 60/60 (name breaks it: g first);
# lane-j and lane-i tie on counted 40 (calls breaks it: j first).
PAIRS='lane-a|repos/Org/app/pulls/N|120|130
lane-b|repos/Org/app/issues/N/comments|110|110
lane-c|search/issues|100|100
lane-d|repos/Org/web/commits/SHA|90|95
lane-e|repos/Org/web/pulls/N|80|80
lane-f|rate_limit|70|70
lane-h|installation/repositories|60|60
lane-g|repos/Org/app/check-runs/N|60|60
lane-i|repos/Org/app/pulls/N|40|41
lane-j|repos/Org/app/pulls|40|45
lane-k|repos/Org/web|30|30
lane-l|repos/Org/web/branches|20|20'
while IFS='|' read -r L C K N; do
  led hub "$SINCE" "$L" core "$C" 10 10
  led pool-1 "$MID" "$L" core "$C" 10 10
  led hub "$CUR" "$L" core "$C" $((N - 20)) $((K - 20))
done <<<"$PAIRS"
# B2: quiet-lane only outside the window; gql-lane only GraphQL.
led hub "$BEFORE" quiet-lane core repos/Org/app/pulls/N 50 50
led hub "$OLD" quiet-lane core repos/Org/app/pulls/N 50 50
led hub "$CUR" gql-lane graphql graphql 500 500
led pool-1 "$MID" gql-lane - /graphql 7 7
# B1b: 3 merges inside 24 h, 1 at 30 h.
for m in 1:2 2:3 3:20 4:30; do
  sql "INSERT INTO ledgers (kind,key,status,created_at,updated_at) VALUES ('merge',?,'merged',?,?)" \
    "https://github.com/Org/app/pull/${m%%:*}" "$(iso "${m#*:}")" "$(iso "${m#*:}")"
done
TOP10='lane-a repos/Org/app/pulls/N 120
lane-b repos/Org/app/issues/N/comments 110
lane-c search/issues 100
lane-d repos/Org/web/commits/SHA 90
lane-e repos/Org/web/pulls/N 80
lane-f rate_limit 70
lane-g repos/Org/app/check-runs/N 60
lane-h installation/repositories 60
lane-j repos/Org/app/pulls 40
lane-i repos/Org/app/pulls/N 40'

# ============================================================================
echo "B1: top 10 and per-PR numbers, --merged 4"
OUT=$(report --merged 4); RC=$?
eq "B1 rc" "$RC" 0
eq "B1 state file written" "$([ -s "$SF" ] && echo yes)" yes
eq "B1 source" "$(jq -r .source "$SF")" fleet
eq "B1 top has 10" "$(jq '.top | length' "$SF")" 10
eq "B1 top in rank order" "$(jq -r '.top[] | "\(.lane) \(.path_class) \(.counted)"' "$SF")" "$TOP10"
eq "B1 the 11th and 12th pairs are absent" "$(jq '[.top[] | select(.lane == "lane-k" or .lane == "lane-l")] | length' "$SF")" 0
eq "B1 rest_counted" "$(jq .totals.rest_counted "$SF")" 820
eq "B1 rest_calls" "$(jq .totals.rest_calls "$SF")" 841
eq "B1 per-PR counted 820/4" "$(jq .per_merged_pr.counted "$SF")" 205
eq "B1 per-PR calls 841/4 rounded to 1 place" "$(jq .per_merged_pr.calls "$SF")" 210.3
eq "B1 merged source" "$(jq -r .merged.source "$SF")" "--merged (caller)"
eq "B1 source line" "$(sed -n 1p <<<"$OUT" | grep -c 'fleet (D1)')" 1
eq "B1 per-PR line" "$(grep -c '^CALLS PER MERGED PR calls=210.3 counted=205 merged=4 ' <<<"$OUT")" 1
TXT_TOP=$(awk '/^TOP 10 \(lane, endpoint class\)/{f=1; getline; next} f && /^$/{exit} f{print $3, $4, $1}' <<<"$OUT")
eq "B1 the text top 10 equals the json top 10" "$TXT_TOP" "$TOP10"
eq "B1 repo block names Org/app" "$(jq -r '.repos[] | select(.repo == "Org/app") | .counted' "$SF")" 370
eq "B1 lane_hour sums both boxes" "$(jq -r --arg h "$SINCE" '.lane_hour[] | select(.hour == $h and .lane == "lane-a") | .calls' "$SF")" 10

echo "B1b: the merge count from GET /api/metrics/dora"
: > "$T/w.log"
report --json > "$T/b1b.json"; RC=$?
eq "B1b rc" "$RC" 0
eq "B1b merged.count" "$(jq .merged.count "$T/b1b.json")" 3
eq "B1b merged.source names the route" "$(jq -r .merged.source "$T/b1b.json" | grep -c 'GET /api/metrics/dora')" 1
eq "B1b per-PR counted 820/3" "$(jq .per_merged_pr.counted "$T/b1b.json")" 273.3
eq "B1b per-PR calls 841/3" "$(jq .per_merged_pr.calls "$T/b1b.json")" 280.3
eq "B1b one dora read" "$(grep -c '^GET /api/metrics/dora?days=1 200' "$T/w.log")" 1

echo "B2: a lane with no rows in the window is absent, not 0"
eq "B2 quiet-lane absent from json" "$(jq '[.lane_hour[], .top[] | select(.lane == "quiet-lane" or .lane == "gql-lane")] | length' "$SF")" 0
eq "B2 quiet-lane absent from text" "$(grep -c 'quiet-lane\|gql-lane' <<<"$OUT")" 0
eq "B2 no zero row" "$(jq '[.lane_hour[] | select(.calls == 0)] | length' "$SF")" 0
eq "B2 graphql calls counted apart" "$(jq .totals.graphql_calls "$SF")" 507

echo "B4: --merged 0"
OUT=$(report --merged 0); RC=$?
eq "B4 rc" "$RC" 0
eq "B4 per-PR null" "$(jq .per_merged_pr.counted "$SF")" null
eq "B4 why" "$(jq -r .per_merged_pr_why "$SF")" "no merges in window"
eq "B4 text" "$(grep -c '^CALLS PER MERGED PR n/a (no merges in window)$' <<<"$OUT")" 1

echo "B5: file names per window"
rm -f "$H/state/gh-budget/"*.json
report --window 7d --merged 1 >/dev/null; eq "B5 7d rc" "$?" 0
eq "B5 7d file" "$([ -s "$H/state/gh-budget/$TODAY-7d.json" ] && echo yes)" yes
eq "B5 7d is not the 24h file" "$([ -e "$SF" ] && echo yes || echo no)" no
eq "B5 7d window hours" "$(jq .window.hours "$H/state/gh-budget/$TODAY-7d.json")" 168
report --window 24h --merged 1 >/dev/null; eq "B5 24h rc" "$?" 0
eq "B5 24h file" "$([ -s "$SF" ] && echo yes)" yes
rm -f "$H/state/gh-budget/"*.json
report --window 3x 2>/dev/null; eq "B5 bad window rc" "$?" 2
eq "B5 bad window writes nothing" "$(ls "$H/state/gh-budget/" 2>/dev/null | wc -l)" 0

echo "F3: --merged x"
ERR=$(report --merged x 2>&1 >/dev/null); eq "F3 rc" "$?" 2
eq "F3 usage" "$(grep -c '^usage: gh-budget-report.sh' <<<"$ERR")" 1
eq "F3 no file" "$(ls "$H/state/gh-budget/" 2>/dev/null | wc -l)" 0

# ---- this box's hour files ----------------------------------------------------
# The 14-column line gh_ledger_append writes; a legacy 10-column line has no
# resource (column 11), which reads as REST unless its class is graphql.
LD="$H/state/gh-rest-ledger"; mkdir -p "$LD"
line14() { printf '%s:00:00Z\t%s\t-\tGET\t%s\t200\t%s\t4000\t0\tapp-1\t%s\trest\t1\t5000\n' "$1" "$2" "$4" "$5" "$3"; }
line10() { printf '%s:00:00Z\t%s\t-\tGET\t%s\t200\t%s\t4000\t0\tapp-1\n' "$1" "$2" "$3" "$4"; }
H1=$(hr 1); H30=$(hr 30)
{
  line14 "$H1" l1 core repos/Org/app/pulls/N 1
  line14 "$H1" l1 core repos/Org/app/pulls/N 0
  line10 "$H1" l2 /repos/Org/app/issues/N/comments 1
  line14 "$H1" l3 search search/issues 1
  line14 "$H1" l4 core rate_limit 1
  line14 "$H1" l4 core installation/repositories 1
  line14 "$H1" l5 core repos/Org 1
  line14 "$H1" l5 core repos/Org/appN/commits/SHA 1
  line14 "$H1" g1 graphql graphql 1
  line10 "$H1" g2 /graphql 1
  line14 "$H1" g3 graphql repos/Org/app/pulls/N 1
} > "$LD/$H1.tsv"
for _ in 1 2 3 4 5; do line14 "$H30" old-lane core repos/Org/app/pulls/N 1; done > "$LD/$H30.tsv"

echo "B6: --local reads this box's hour files"
: > "$T/w.log"
OUT=$(report --local --merged 2); RC=$?
eq "B6 rc" "$RC" 0
eq "B6 source" "$(jq -r .source "$SF")" local
eq "B6 no worker read" "$(grep -c gh-ledger "$T/w.log")" 0
eq "B6 rest calls" "$(jq .totals.rest_calls "$SF")" 8
eq "B6 rest counted" "$(jq .totals.rest_counted "$SF")" 7
eq "B6 graphql calls" "$(jq .totals.graphql_calls "$SF")" 3
eq "B6 repos" "$(jq -r '.repos[] | "\(.repo) \(.calls) \(.counted)"' "$SF")" "(no repo) 4 4
Org/app 3 2
Org/appN 1 1"
eq "B6 the 30h file is not counted" "$(jq '[.lane_hour[] | select(.lane == "old-lane")] | length' "$SF")" 0
eq "B6 graphql lanes absent" "$(jq '[.top[] | select(.lane | startswith("g"))] | length' "$SF")" 0
eq "B6 per-PR counted 7/2" "$(jq .per_merged_pr.counted "$SF")" 3.5
eq "B6 source line" "$(sed -n 1p <<<"$OUT" | grep -c "this box's ledger only")" 1

echo "F1: worker unreachable"
OUT=$(JOBS_URL=http://127.0.0.1:1 report --merged 2); RC=$?
eq "F1 rc" "$RC" 0
L1=$(sed -n 1p <<<"$OUT")
eq "F1 first line" "$(grep -c "fleet read failed .* this box's ledger only" <<<"$L1")" 1
eq "F1 source" "$(jq -r .source "$SF")" local
eq "F1 the local numbers" "$(jq .totals.rest_calls "$SF")" 8

echo "F2: an old worker that does not echo group"
curl -sS -X PUT "$JOBS_URL/__strip-group" -d '{"on":true}' >/dev/null
OUT=$(report --merged 2); RC=$?
curl -sS -X PUT "$JOBS_URL/__strip-group" -d '{"on":false}' >/dev/null
eq "F2 rc" "$RC" 0
eq "F2 first line" "$(sed -n 1p <<<"$OUT" | grep -c "fleet read failed (no group echo) — this box's ledger only")" 1
eq "F2 source" "$(jq -r .source "$SF")" local

echo "W1: the state dir cannot be created"
mv "$H/state/gh-budget" "$T/gb.save"; : > "$H/state/gh-budget"
OUT=$(report --merged 4 2>/dev/null); RC=$?
eq "W1 rc 3" "$RC" 3
eq "W1 the text still prints" "$(grep -c '^TOP 10 (lane, endpoint class)' <<<"$OUT")" 1
rm -f "$H/state/gh-budget"; mv "$T/gb.save" "$H/state/gh-budget"

echo "B3: the digest carries the block"
report --merged 1 >/dev/null
: > "$T/w.log"; : > "$H/logs/ALERTS.log"
bash "$H/bin/dora-digest.sh" --window 24h --no-send; RC=$?
DJ="$H/state/dora/$TODAY.json"
eq "B3 rc" "$RC" 0
eq "B3 status ok" "$(jq -r .gh_budget.status "$DJ")" ok
eq "B3 top 5" "$(jq '.gh_budget.top | length' "$DJ")" 5
eqn "B3 top[0] equals the report file's" "$(jq -c '.gh_budget.top[0]' "$DJ")" "$(jq -c '.top[0]' "$SF")"
eqn "B3 per-PR equals the report file's" "$(jq -c '.gh_budget.per_merged_pr' "$DJ")" "$(jq -c '.per_merged_pr' "$SF")"
eq "B3 the report used the digest's merge count" "$(jq .merged.count "$SF")" 3
eq "B3 one github REST line" "$(grep -c '^github REST: ' "$H/state/dora/latest.txt")" 1
eq "B3 the line" "$(grep '^github REST: ' "$H/state/dora/latest.txt")" \
  "github REST: 841 calls, 820 charged, 273.3/merged PR; top pollers: lane-a repos/Org/app/pulls/N 120 | lane-b repos/Org/app/issues/N/comments 110 | lane-c search/issues 100 | lane-d repos/Org/web/commits/SHA 90 | lane-e repos/Org/web/pulls/N 80"
eq "B3 the line sits before sources:" "$(grep -A1 '^github REST: ' "$H/state/dora/latest.txt" | tail -1 | cut -c1-8)" "sources:"
eq "B3 one dora read" "$(grep -c '^GET /api/metrics/dora' "$T/w.log")" 1
eq "B3 three grouped reads" "$(grep -c '^GET /api/metrics/gh-ledger?since=.*&group=' "$T/w.log")" 3

echo "B3b: DORA_GH_BUDGET=0"
: > "$T/w.log"
DORA_GH_BUDGET=0 bash "$H/bin/dora-digest.sh" --window 24h --no-send; RC=$?
eq "B3b rc" "$RC" 0
eq "B3b status off" "$(jq -r .gh_budget.status "$DJ")" off
eq "B3b no line" "$(grep -c '^github REST:' "$H/state/dora/latest.txt")" 0
eq "B3b no gh-ledger read" "$(grep -c gh-ledger "$T/w.log")" 0
DORA_GH_BUDGET=no bash "$H/bin/dora-digest.sh" --window 24h --no-send
eq "B3b a value that is not 1 is off" "$(jq -r .gh_budget.status "$DJ")" off

echo "B3c: a report that exits 7"
cp "$H/bin/gh-budget-report.sh" "$T/gbr.save"
printf '#!/bin/bash\necho "{not json"\nexit 7\n' > "$H/bin/gh-budget-report.sh"
: > "$H/logs/dora-digest.log"
bash "$H/bin/dora-digest.sh" --window 24h --no-send; RC=$?
cp "$T/gbr.save" "$H/bin/gh-budget-report.sh"
eq "B3c digest rc 0" "$RC" 0
eq "B3c status error" "$(jq -r .gh_budget.status "$DJ")" error
eq "B3c the line" "$(grep '^github REST:' "$H/state/dora/latest.txt")" "github REST: n/a (error)"
eq "B3c one log line naming rc 7" "$(grep -c 'gh budget report failed rc=7' "$H/logs/dora-digest.log")" 1
eq "B3c no ALERTS line" "$(grep -c . "$H/logs/ALERTS.log")" 0

echo "R1: state/gh-budget/ retention"
GB="$H/state/gh-budget"; mkdir -p "$GB"
mk() { : > "$GB/$1"; touch -d "@$((NOW - $2 * 86400))" "$GB/$1"; }
mk 2000-01-01.json 100; mk 2000-01-02-7d.json 91; mk 2000-01-03.json 10; mk notes.txt 100
: > "$H/logs/gh-budget-report.log"
report --merged 1 >/dev/null
eq "R1 100d and 91d files gone" "$(ls "$GB" | grep -c '^2000-01-0[12]')" 0
eq "R1 10d file kept" "$([ -e "$GB/2000-01-03.json" ] && echo yes)" yes
eq "R1 a file the sweep does not name is kept" "$([ -e "$GB/notes.txt" ] && echo yes)" yes
eq "R1 today's file kept" "$([ -s "$SF" ] && echo yes)" yes
eq "R1 one sweep line" "$(grep -c 'swept 2 file(s) older than 90d' "$H/logs/gh-budget-report.log")" 1
GH_BUDGET_KEEP_DAYS=5 report --merged 1 >/dev/null
eq "R1 GH_BUDGET_KEEP_DAYS=5 sweeps the 10d file" "$([ -e "$GB/2000-01-03.json" ] && echo kept || echo gone)" gone
mk 2000-01-04.json 10; : > "$H/logs/gh-budget-report.log"
GH_BUDGET_KEEP_DAYS=0 report --merged 1 >/dev/null
eq "R1 KEEP_DAYS=0 uses 90" "$([ -e "$GB/2000-01-04.json" ] && echo kept || echo gone)" kept
eq "R1 KEEP_DAYS=0 says so" "$(grep -c "GH_BUDGET_KEEP_DAYS='0' is not a positive integer — using 90" "$H/logs/gh-budget-report.log")" 1
curl -sS -X PUT "$JOBS_URL/__setting" -d '{"key":"conf.gh-budget-report.keep_days","value":"5"}' >/dev/null
rm -f "$H/state/settings-cache.json"
report --merged 1 >/dev/null
eq "R1 the settings row conf.gh-budget-report.keep_days=5 sweeps the 10d file" "$([ -e "$GB/2000-01-04.json" ] && echo kept || echo gone)" gone

echo
echo "gh-budget-report: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
