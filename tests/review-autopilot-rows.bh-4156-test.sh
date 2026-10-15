#!/bin/bash
# tests/review-autopilot-rows.bh-4156-test.sh — BH-4156 C1: with the
# `no-twin-ledgers` flag up, the review autopilot keeps its record in `ledgers`
# rows and writes no record file under state/review-autopilot/.
#
#   R1  a wiped state dir, a ledger that holds a `reviewed` row (PR 7) and a
#       `status=reviewed-unposted` row with its cached body (PR 8): no model
#       call, the cached body is posted once, PR 8's row settles to `reviewed`,
#       and no file but diff-* appears under state/review-autopilot/
#   R2  an unreadable row (the worker answers 503 on reads) buys nothing for
#       that head, posts nothing and logs one line per head; a row whose state
#       is no known shape buys nothing too
#   R3  legacy import: leftover key and body files become rows and are removed;
#       a second tick is a no-op; a leftover file never overwrites a row that is
#       already there; a failed import keeps the file and buys nothing
#   R4  a body over the ledger's detail limit (4000) is never a cut row: it
#       is cached in the local <key>.body file, the next tick re-posts it with
#       no model call, and a post that keeps failing goes unposted-terminal
#       after POST_TRIES with one alert and no second review
#   R3b a legacy body over the limit stays as that local cache: its key
#       imports and the next tick posts it with no model call
#   R8  a record or cap write that fails after a billed call is kept locally
#       (<key>.pending, the count file) and written first on the next tick:
#       the bounds hold and nothing is bought again
#   R5  the daily cap is counted from the review_autopilot_cap row (no count-*
#       file), a leftover count file folds into the row, and an unreadable cap
#       row with a cap set buys nothing
#   R6  a new head in row mode: one review, rows written by the real writer,
#       a second tick reads them and buys nothing
#   R7  the flag down: today's file record, no ledger request for this lane
#
# The REAL bin/review-autopilot.sh in a scratch $HARNESS with gh, agent-call,
# beat and the jobs worker (a stateful fake /api/ledger) stubbed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-autopilot-rows.bh-4156-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# A pinned clock (the lane's REVIEW_AUTOPILOT_NOW seam). No wall-clock read.
NOW=1792022400
DAY=$(date -u -d "@$NOW" '+%Y%m%d')
CREATED="2026-01-01T00:00:00Z"

H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/env" "$H/state" "$H/flags" "$T/fakebin"
scratch_install_closure bin/review-autopilot.sh "$H" >/dev/null || { echo "FAIL: closure of bin/review-autopilot.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || { echo "FAIL: closure of bin/fleet-conf.sh"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "FAIL: closure of bin/alert-line.sh"; exit 1; }
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
printf 'HARNESS_SECRET=secret-fixture-1\nJOBS_URL=https://jobs.fixture.test\n' > "$H/env/global.env"
mrs_fixture "$H" p1

STATE="$H/state/review-autopilot"
RLOG="$H/logs/review-autopilot.log"
LS="$T/ledger"            # the fake worker's row store
SHA7=7777777777770000000000000000000000000000
SHA8=8888888888880000000000000000000000000000
RK7="o/p1#7@${SHA7:0:12}"
RK8="o/p1#8@${SHA8:0:12}"

# --- the fake jobs worker ----------------------------------------------------
# /api/ledger is stateful, in the route's own shapes (worker/jobs/src/routes/
# ledger.js): GET one row -> 200 {"ledger":{...}} or 404; PUT -> upsert on
# (kind, key), status replaced, detail COALESCEd and cut at 4000 like the route.
# Faults: $LS/.down-get (every ledger GET 503), $LS/.down-get-<kind>,
# $LS/.down-put. Every ledger request is logged to $LS/.log as
# "<METHOD> <kind> <key> <detail bytes>". Any other GET is a 404 (no route,
# so flags fall to their files and model routes to the box cache); any other
# write is 200.
{ printf '#!/bin/bash\nLS=%q\n' "$LS"; cat <<'EOF'
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary|-d) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w|-o|--max-time) shift 2;;
    -*) shift;;
    *) URL="$1"; shift;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
P="/${URL#*://*/}"
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${P#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
case "$P" in
  /api/ledger|/api/ledger\?*) ;;
  *) if [ "$METHOD" = GET ]; then printf '{"error":"not found"}\n404'; else printf '{"ok":true}\n200'; fi; exit 0 ;;
esac
mkdir -p "$LS"
if [ "$METHOD" = PUT ]; then
  K=$(jq -r '.kind' <<<"$BODY"); V=$(jq -r '.key' <<<"$BODY")
  printf 'PUT %s %s %s\n' "$K" "$V" "$(jq -j '.detail // ""' <<<"$BODY" | wc -c)" >> "$LS/.log"
  [ -e "$LS/.down-put" ] && { printf '{"error":"d1 down"}\n503'; exit 0; }
  F="$LS/$K/$(jq -nr --arg v "$V" '$v|@uri')"; mkdir -p "$LS/$K"
  OLD='null'; [ -f "$F" ] && OLD=$(cat "$F")
  jq -c --argjson old "$OLD" '{status:(.status|.[0:128]),
        detail:(if (.detail // null) == null then ($old.detail // null) else (.detail|.[0:4000]) end)}' \
     <<<"$BODY" > "$F.tmp" && mv "$F.tmp" "$F"
  printf '{"ledger":%s}\n200' "$(cat "$F")"; exit 0
fi
K=$(ud "$(qp kind)"); V=$(ud "$(qp key)")
printf 'GET %s %s\n' "$K" "$V" >> "$LS/.log"
{ [ -e "$LS/.down-get" ] || [ -e "$LS/.down-get-$K" ]; } && { printf '{"error":"d1 down"}\n503'; exit 0; }
F="$LS/$K/$(jq -nr --arg v "$V" '$v|@uri')"
if [ -f "$F" ]; then printf '{"ledger":%s}\n200' "$(cat "$F")"; else printf '{"error":"not found"}\n404'; fi
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
lf_put() { # lf_put <kind> <key> <status> <detail>
  local f; mkdir -p "$LS/$1"; f="$LS/$1/$(jq -nr --arg v "$2" '$v|@uri')"
  jq -nc --arg s "$3" --arg d "$4" '{status:$s,detail:$d}' > "$f"; }
lf_status() { local f="$LS/$1/$(jq -nr --arg v "$2" '$v|@uri')"; [ -f "$f" ] && jq -r .status "$f"; }
lf_detail() { local f="$LS/$1/$(jq -nr --arg v "$2" '$v|@uri')"; [ -f "$f" ] && jq -j .detail "$f"; }

# --- gh, agent-call, beat ----------------------------------------------------
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  [ -f "$T/gh-comment-fails" ] && { echo "gh: HTTP 502" >&2; exit 1; }
  cat "$BF" >> "$T/posted.txt"; printf '\n=END=\n' >> "$T/posted.txt"; echo post >> "$T/post-count.txt"
  exit 0
fi
case "$*" in
  api\ repos/o/p1/issues/*/comments*) printf '[]\n' ;;
  *repos/o/p1/pulls/[0-9]*)
    printf 'HTTP/2.0 200 OK\r\n\r\n{"state":"open","merged_at":null}\n' ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
cat "$T/model-out" > "$5"
exit 0
EOF
} > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

pulls() { # pulls <num:sha>...
  local a="[]" x
  for x in "$@"; do
    a=$(jq -c --argjson n "${x%%:*}" --arg s "${x#*:}" --arg c "$CREATED" \
      '. + [{number:$n,html_url:"https://github.com/o/p1/pull/\($n)",title:"BH-x: a thing",
             body:"Closes #\($n)",head:{sha:$s,ref:"ticket/x\($n)"},base:{ref:"main"},
             draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
             merged_at:null,closed_at:null,labels:[],state:"open"}]' <<<"$a")
  done
  printf '%s\n' "$a" > "$T/pulls.json"; }

GOOD_REVIEW='Nothing load-bearing was deferred.

VERDICT: MERGE — reads fine'
RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          HARNESS_TEST_SANDBOX=1 REVIEW_AUTOPILOT_NOW="$NOW" JOBS_BOX=box-fixture JOBS_RETRIES=0 \
          REPOS_ROOT="$T/no-repos" env "$@" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
CALLS() { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS() { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
# Every file under state/review-autopilot/ that is not diff-* scratch.
RECFILES() { find "$STATE" -type f ! -name 'diff-*' 2>/dev/null | sed "s|^$STATE/||" | sort | tr '\n' ' '; }
RESET() { scratch_rm "$STATE"; scratch_rm "$LS"; mkdir -p "$LS"
          printf '%s\n' "$GOOD_REVIEW" > "$T/model-out"
          : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
          : > "$T/gh-calls.txt"; : > "$RLOG"; : > "$T/run.log"
          rm -f "$T/gh-comment-fails"; touch "$H/flags/no-twin-ledgers"; }
CACHED="<!-- harness-review-autopilot ${SHA8:0:12} -->
A cached review body fixture. It was paid for and not delivered.

VERDICT: MERGE-WITH-NOTES — a fixture note"

# ---- R1: wiped state, rows hold `reviewed` and `status=reviewed-unposted`
RESET; pulls "7:$SHA7" "8:$SHA8"
lf_put review_autopilot "$RK7" reviewed "reviewed 2026-11-01 09:00:00Z verdict=MERGE
sha=$SHA7"
lf_put review_autopilot "$RK8" reviewed-unposted "status=reviewed-unposted 2026-11-01 09:00:00Z verdict=MERGE-WITH-NOTES tries=1"
lf_put review_autopilot_body "$RK8" cached "$CACHED"
RUN
[ "$(CALLS)" = 0 ] && ok || bad "R1 no model call may be made (calls=$(CALLS)) [$(tail -3 "$RLOG")]"
[ "$(POSTS)" = 1 ] && ok || bad "R1 the cached body must be posted once (posts=$(POSTS)) [$(tail -3 "$RLOG")]"
[ "$(sed '/^=END=$/,$d' "$T/posted.txt")" = "$CACHED" ] && ok || bad "R1 the posted bytes must be the cached body: $(head -3 "$T/posted.txt")"
[[ "$(lf_detail review_autopilot "$RK8")" =~ ^reviewed\ .*\ verdict=MERGE-WITH-NOTES ]] && [ "$(lf_status review_autopilot "$RK8")" = reviewed ] && ok \
  || bad "R1 PR 8's row must settle to reviewed: $(lf_status review_autopilot "$RK8") / $(lf_detail review_autopilot "$RK8")"
[ "$(lf_status review_autopilot_body "$RK8")" != cached ] && ok || bad "R1 the body row must be dropped once it is posted"
[ "$(lf_status review_autopilot "$RK7")" = reviewed ] && ok || bad "R1 PR 7's reviewed row must be untouched"
[ -z "$(RECFILES)" ] && ok || bad "R1 no record file may appear under state/review-autopilot/: $(RECFILES)"
[ ! -e "$STATE/count-p1-$DAY" ] && ok || bad "R1 no count file may be written"
# The same rows, a second tick: nothing to do.
: > "$T/post-count.txt"; RUN
[ "$(CALLS)" = 0 ] && [ "$(POSTS)" = 0 ] && ok || bad "R1 a second tick must buy and post nothing (calls=$(CALLS) posts=$(POSTS))"

# ---- R2: an unreadable row buys nothing
RESET; pulls "7:$SHA7" "8:$SHA8"
touch "$LS/.down-get"
RUN
[ "$(CALLS)" = 0 ] && [ "$(POSTS)" = 0 ] && ok || bad "R2 an unreadable row must buy and post nothing (calls=$(CALLS) posts=$(POSTS))"
[ "$(grep -c 'unreadable' "$RLOG")" = 2 ] && ok || bad "R2 one unreadable line per head (2): $(grep -c 'unreadable' "$RLOG") [$(cat "$RLOG")]"
grep -qF "#7 @${SHA7:0:12}" "$RLOG" && grep -qF "#8 @${SHA8:0:12}" "$RLOG" && ok || bad "R2 the lines must name each head: $(cat "$RLOG")"
[ -z "$(RECFILES)" ] && ok || bad "R2 no record file: $(RECFILES)"
# R2b: a row whose state is no known shape is unreadable too.
RESET; pulls "7:$SHA7"
lf_put review_autopilot "$RK7" bogus "bogus state fixture"
RUN
[ "$(CALLS)" = 0 ] && [ "$(POSTS)" = 0 ] && ok || bad "R2b a corrupt row must buy nothing (calls=$(CALLS))"
grep -q "unreadable state" "$RLOG" && ok || bad "R2b the corrupt row must be logged: $(cat "$RLOG")"
# R2c: the body row unreadable while the record says reviewed-unposted: no buy, no post.
RESET; pulls "8:$SHA8"
lf_put review_autopilot "$RK8" reviewed-unposted "status=reviewed-unposted 2026-11-01 09:00:00Z verdict=MERGE tries=1"
lf_put review_autopilot_body "$RK8" cached "$CACHED"
touch "$LS/.down-get-review_autopilot_body"
RUN
[ "$(CALLS)" = 0 ] && [ "$(POSTS)" = 0 ] && ok || bad "R2c an unreadable body row must buy and post nothing (calls=$(CALLS) posts=$(POSTS))"

# ---- R3: legacy import
RESET; pulls "7:$SHA7" "8:$SHA8"
mkdir -p "$STATE"
printf 'reviewed 2026-11-01 09:00:00Z verdict=MERGE\nsha=%s' "$SHA7" > "$STATE/o-p1-7-${SHA7:0:12}"
printf 'status=reviewed-unposted 2026-11-01 09:00:00Z verdict=MERGE-WITH-NOTES tries=1\n' > "$STATE/o-p1-8-${SHA8:0:12}"
printf '%s' "$CACHED" > "$STATE/o-p1-8-${SHA8:0:12}.body"
touch "$T/gh-comment-fails"     # keep PR 8 unposted, so the imported rows stay readable as imported
RUN
[ "$(CALLS)" = 0 ] && ok || bad "R3 an imported record must buy nothing (calls=$(CALLS)) [$(tail -3 "$RLOG")]"
[ -z "$(RECFILES)" ] && ok || bad "R3 the legacy files must be removed after import: $(RECFILES)"
[ "$(lf_detail review_autopilot "$RK7")" = "reviewed 2026-11-01 09:00:00Z verdict=MERGE
sha=$SHA7" ] && [ "$(lf_status review_autopilot "$RK7")" = reviewed ] && ok \
  || bad "R3 the key file must become its row whole: $(lf_status review_autopilot "$RK7") / $(lf_detail review_autopilot "$RK7")"
[ "$(lf_detail review_autopilot_body "$RK8")" = "$CACHED" ] && [ "$(lf_status review_autopilot_body "$RK8")" = cached ] && ok \
  || bad "R3 the body file must become its row byte for byte"
[[ "$(lf_detail review_autopilot "$RK8")" =~ ^status=reviewed-unposted\ .*\ tries=2$ ]] && ok \
  || bad "R3 PR 8's post failed once more, so tries=2: $(lf_detail review_autopilot "$RK8")"
cp "$LS/.log" "$T/r3-first.log"
# Second tick, comment still failing: idempotent (no file, no new row value
# for PR 7, no model call).
D7=$(lf_detail review_autopilot "$RK7"); RUN
[ "$(CALLS)" = 0 ] && [ -z "$(RECFILES)" ] && [ "$(lf_detail review_autopilot "$RK7")" = "$D7" ] && ok \
  || bad "R3 a second tick must be a no-op for the import (calls=$(CALLS) files=$(RECFILES))"
grep -q "PUT review_autopilot $RK7" <(sed -n "$(( $(wc -l < "$T/r3-first.log") + 1 )),\$p" "$LS/.log") \
  && bad "R3 a second tick must not PUT PR 7's row again" || ok
# A leftover file never overwrites a row that is already there.
printf 'status=reviewed-unposted 2026-10-01 09:00:00Z verdict=BLOCK tries=0\n' > "$STATE/o-p1-7-${SHA7:0:12}"
RUN
[ "$(lf_detail review_autopilot "$RK7")" = "$D7" ] && ok || bad "R3 a stale leftover file overwrote the row: $(lf_detail review_autopilot "$RK7")"
[ ! -e "$STATE/o-p1-7-${SHA7:0:12}" ] && ok || bad "R3 the stale leftover file must be removed"
[ "$(CALLS)" = 0 ] && ok || bad "R3 the stale leftover must buy nothing (calls=$(CALLS))"
# R3b: a legacy body over the limit stays as the local cache; its key imports.
RESET; pulls "8:$SHA8"; mkdir -p "$STATE"
printf 'status=reviewed-unposted 2026-11-01 09:00:00Z verdict=MERGE tries=1\n' > "$STATE/o-p1-8-${SHA8:0:12}"
{ printf '%s\n' "<!-- harness-review-autopilot ${SHA8:0:12} -->"; head -c 4200 /dev/zero | tr '\0' 'y'; printf '\n\nVERDICT: MERGE — legacy long\n'; } > "$STATE/o-p1-8-${SHA8:0:12}.body"
RUN
[ "$(CALLS)" = 0 ] && [ "$(POSTS)" = 1 ] && ok || bad "R3b the legacy long body posts with no model call (calls=$(CALLS) posts=$(POSTS)) [$(cat "$RLOG")]"
grep -q 'VERDICT: MERGE — legacy long' "$T/posted.txt" && ok || bad "R3b the posted bytes are the legacy body"
[ "$(lf_status review_autopilot "$RK8")" = reviewed ] && [ -z "$(RECFILES)" ] && ok   || bad "R3b the head settles and both files go: $(lf_status review_autopilot "$RK8") / $(RECFILES)"
# A failed import keeps the file and buys nothing for that head.
RESET; pulls "7:$SHA7"; mkdir -p "$STATE"
printf 'failed 2026-11-01 09:00:00Z n=1 rc=1\n' > "$STATE/o-p1-7-${SHA7:0:12}"
touch "$LS/.down-put"
RUN
[ -e "$STATE/o-p1-7-${SHA7:0:12}" ] && ok || bad "R3 a failed import must keep the file"
[ "$(CALLS)" = 0 ] && ok || bad "R3 a head whose file could not be imported must buy nothing (calls=$(CALLS)) [$(cat "$RLOG")]"

# ---- R4: a body over the ledger's detail limit is cached in the local file
LONGBODY() { { head -c 4200 /dev/zero | tr '\0' 'x'; printf '\n\nVERDICT: MERGE — long fixture\n'; } > "$T/model-out"; }
BODY7="o-p1-7-${SHA7:0:12}.body"
RESET; pulls "7:$SHA7"; LONGBODY
touch "$T/gh-comment-fails"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "R4 the first tick buys one review (calls=$(CALLS))"
[ "$(lf_status review_autopilot_body "$RK7")" = "" ] && ok || bad "R4 an oversize body must not be written as a row: $(lf_status review_autopilot_body "$RK7")"
OVER=$(awk '$1=="PUT" && $NF > 4000' "$LS/.log")
[ -z "$OVER" ] && ok || bad "R4 a detail over 4000 bytes was sent: $OVER"
grep -q "cached in the local file .*$BODY7" "$RLOG" && ok || bad "R4 the local cache must be logged: $(cat "$RLOG")"
[ "$(RECFILES)" = "$BODY7 " ] && grep -q 'VERDICT: MERGE — long fixture' "$STATE/$BODY7" && ok || bad "R4 the whole body is cached in $BODY7: $(RECFILES)"
[[ "$(lf_detail review_autopilot "$RK7")" =~ ^status=reviewed-unposted ]] && ok || bad "R4 the record is reviewed-unposted: $(lf_detail review_autopilot "$RK7")"
rm -f "$T/gh-comment-fails"; RUN
grep -q 'cached body is gone' "$RLOG" && bad "R4 the next tick must not take the body-gone path: $(cat "$RLOG")" || ok
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "R4 the next tick re-posts the cached body with no model call (calls=$(CALLS) posts=$(POSTS))"
grep -q 'VERDICT: MERGE — long fixture' "$T/posted.txt" && ok || bad "R4 the posted bytes are the cached long body"
[ "$(lf_status review_autopilot "$RK7")" = reviewed ] && [ -z "$(RECFILES)" ] && ok   || bad "R4 the head settles and the local cache goes: $(lf_status review_autopilot "$RK7") / $(RECFILES)"
# R4b: the post keeps failing: bounded by POST_TRIES, one alert, never a second review.
RESET; pulls "7:$SHA7"; LONGBODY; touch "$T/gh-comment-fails"; : > "$H/logs/ALERTS.log"
for _ in 1 2 3 4; do RUN REVIEW_AUTOPILOT_POST_TRIES=3; done
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 0 ] && ok || bad "R4b a failing post never buys a second review (calls=$(CALLS) posts=$(POSTS)) [$(cat "$RLOG")]"
[ "$(lf_status review_autopilot "$RK7")" = unposted-terminal ] && ok || bad "R4b the head goes unposted-terminal: $(lf_status review_autopilot "$RK7") / $(lf_detail review_autopilot "$RK7")"
[ "$(grep -c "unposted-terminal" "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && grep -qF "$BODY7" "$H/logs/ALERTS.log" && ok   || bad "R4b one alert naming the local cache: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ -s "$STATE/$BODY7" ] && ok || bad "R4b the paid body is kept for the operator"

# ---- R5: the cap is counted from the row
RESET; pulls "7:$SHA7"
lf_put review_autopilot_cap "p1 $DAY" 2 ""
RUN REVIEW_AUTOPILOT_DAILY_CAP=2
[ "$(CALLS)" = 0 ] && ok || bad "R5 a cap row of 2 with cap 2 must buy nothing (calls=$(CALLS))"
grep -q 'daily review cap 2 reached' "$RLOG" && ok || bad "R5 the cap stop must be logged: $(cat "$RLOG")"
RESET; pulls "7:$SHA7"
lf_put review_autopilot_cap "p1 $DAY" 1 ""
RUN REVIEW_AUTOPILOT_DAILY_CAP=2
[ "$(CALLS)" = 1 ] && [ "$(lf_status review_autopilot_cap "p1 $DAY")" = 2 ] && ok \
  || bad "R5 one review charges the row to 2 (calls=$(CALLS) row=$(lf_status review_autopilot_cap "p1 $DAY"))"
[ -z "$(RECFILES)" ] && ok || bad "R5 no count file: $(RECFILES)"
# A leftover count file higher than the row folds into the row and is removed.
RESET; pulls "7:$SHA7"; mkdir -p "$STATE"
lf_put review_autopilot_cap "p1 $DAY" 1 ""
echo 5 > "$STATE/count-p1-$DAY"
RUN REVIEW_AUTOPILOT_DAILY_CAP=5
[ "$(CALLS)" = 0 ] && [ "$(lf_status review_autopilot_cap "p1 $DAY")" = 5 ] && [ ! -e "$STATE/count-p1-$DAY" ] && ok \
  || bad "R5 a leftover count of 5 must fold into the row and cap (calls=$(CALLS) row=$(lf_status review_autopilot_cap "p1 $DAY") files=$(RECFILES))"
# An unreadable cap row with a cap set buys nothing.
RESET; pulls "7:$SHA7"
touch "$LS/.down-get-review_autopilot_cap"
RUN REVIEW_AUTOPILOT_DAILY_CAP=5
[ "$(CALLS)" = 0 ] && ok || bad "R5 an unreadable cap row with a cap must buy nothing (calls=$(CALLS))"

# ---- R6: a new head, the real writer, then a second tick reads its rows
RESET; pulls "7:$SHA7"
RUN
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "R6 a new head buys and posts once (calls=$(CALLS) posts=$(POSTS)) [$(tail -3 "$RLOG")]"
[ "$(lf_status review_autopilot "$RK7")" = reviewed ] && [ "$(lf_detail review_autopilot "$RK7" | sed -n 2p)" = "sha=$SHA7" ] && ok \
  || bad "R6 the row must be reviewed with the full sha: $(lf_detail review_autopilot "$RK7")"
[ "$(lf_status review_autopilot_cap "p1 $DAY")" = 1 ] && ok || bad "R6 the cap row must count 1"
[ "$(lf_status review_autopilot_pr "o/p1#7")" = reviewed ] && ok || bad "R6 the PR's newest-reviewed pointer must be written"
[ -z "$(RECFILES)" ] && ok || bad "R6 no record file: $(RECFILES)"
RUN
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "R6 the second tick must read the row and buy nothing (calls=$(CALLS) posts=$(POSTS))"

# ---- R8: a failed write after a billed call is kept and written first next tick
RESET; pulls "7:$SHA7"; : > "$T/model-out"
lf_put review_autopilot_cap "p1 $DAY" 1 ""
touch "$LS/.down-put"
RUN REVIEW_AUTOPILOT_DAILY_CAP=9
[ "$(CALLS)" = 1 ] && ok || bad "R8 the first tick buys one (empty) review (calls=$(CALLS))"
[ "$(cat "$STATE/o-p1-7-${SHA7:0:12}.pending" 2>/dev/null | head -1 | cut -d' ' -f1,4)" = "empty n=1" ] && ok   || bad "R8 the failed record write is kept in .pending: $(RECFILES) [$(cat "$STATE"/*.pending 2>/dev/null)]"
[ "$(cat "$STATE/count-p1-$DAY" 2>/dev/null)" = 2 ] && ok || bad "R8 the failed cap write is kept in the count file: $(RECFILES)"
RUN REVIEW_AUTOPILOT_DAILY_CAP=9
[ "$(CALLS)" = 1 ] && ok || bad "R8 a record that still cannot write buys nothing (calls=$(CALLS)) [$(tail -2 "$RLOG")]"
rm -f "$LS/.down-put"; RUN REVIEW_AUTOPILOT_DAILY_CAP=9
[ "$(CALLS)" = 2 ] && [ "$(lf_status review_autopilot "$RK7")" = empty-terminal ] && ok   || bad "R8 the pending n=1 lands first, so the next empty answer is terminal (calls=$(CALLS) row=$(lf_detail review_autopilot "$RK7"))"
[ "$(lf_status review_autopilot_cap "p1 $DAY")" = 3 ] && [ -z "$(RECFILES)" ] && ok   || bad "R8 the count file folds into the row (2) and the review charges it to 3: $(lf_status review_autopilot_cap "p1 $DAY") / $(RECFILES)"
RUN REVIEW_AUTOPILOT_DAILY_CAP=9
[ "$(CALLS)" = 2 ] && ok || bad "R8 the terminal head buys nothing more (calls=$(CALLS))"

# ---- R7: the flag down: the file record, and no ledger request
RESET; pulls "7:$SHA7"; rm -f "$H/flags/no-twin-ledgers"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "R7 flag down buys one review (calls=$(CALLS))"
[[ "$(head -1 "$STATE/o-p1-7-${SHA7:0:12}" 2>/dev/null)" =~ ^reviewed\ .*verdict=MERGE$ ]] && ok || bad "R7 flag down writes today's key file"
[ -e "$STATE/count-p1-$DAY" ] && ok || bad "R7 flag down writes today's count file"
[ ! -s "$LS/.log" ] && ok || bad "R7 flag down makes no ledger request: $(cat "$LS/.log")"

echo "review-autopilot-rows.bh-4156: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
