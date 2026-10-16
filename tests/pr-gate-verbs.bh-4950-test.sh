#!/bin/bash
# tests/pr-gate-verbs.bh-4950-test.sh — BH-4953 (BH-4950.0): the three gate
# verbs in bin/lib/jobs/jobs.sh — pr_gate_event_put, pr_gate_facts and
# pr_needs_review — driven through the REAL bin/jobs-client.sh against a curl
# shim that records what was SENT and answers a scripted status.
#
# WHAT IT PINS.
#   S1  pr_gate_event_put's exact METHOD PATH BODY, ints as JSON numbers.
#   S2  a bad call (unknown field, held=2, non-numeric number, missing source)
#       is rc 1 and sends NOTHING — a typo is never a silent no-op.
#   S3  pr_gate_facts prints the worker's JSON verbatim at rc 0.
#   S4  pr_needs_review prints TSV `number head url hotfix nudged approved_at`,
#       with '-' for an empty field, at rc 0.
#   S5  `rows: []` is rc 2 with nothing printed: a MEASURED none.
#   S6  a 5xx, a 404 (an old worker without the route), a transport failure
#       and a 200 with no `.rows` are each rc 1 with nothing printed.
#   S7  none of the three is gated on the `pr-state-rows` flag.
#
# The worker half (routes, fold, eligibility) is worker/jobs/test/
# pr-state-needs-review.test.js, run below when node:sqlite is available. The
# new source it pins: "$DIR/worker/jobs/src/lib/pr-gate.js".
#
# No clock, no network: every value is a literal, nothing outside $T is written.
#
# Run from anywhere: tests/pr-gate-verbs.bh-4950-test.sh  (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/env" "$H/flags" "$H/logs" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
[ -f "$H/bin/lib/jobs/jobs.sh" ] || { echo "FAIL: jobs.sh not in the closure"; exit 1; }
REQ="$T/req.log"
ERR="$T/err.log"

# Records METHOD URL BODY, then answers $CURL_BODY / $CURL_STATUS. The flags
# API is always a 404, so a verb that consulted the flag would read it down.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s|-L|-f) shift;;
    *) URL="$1"; shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
DEFBODY='{"ok":true}'
printf '%s\n%s\n' "${CURL_BODY:-$DEFBODY}" "${CURL_STATUS:-200}"
CURL
chmod +x "$T/fakebin/curl"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
eval "$DRIVE_CODE"
DRV

drv() { # drv <shell snippet> — prints its stdout; caller reads $?
  DRIVE_CODE="$1" \
  PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
  JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
  CURL_MODE="${CURL_MODE:-ok}" CURL_STATUS="${CURL_STATUS:-}" CURL_BODY="${CURL_BODY:-}" \
  bash "$T/drive.sh" 2>>"$ERR"
}
reset()   { : > "$REQ"; : > "$ERR"; }
lastreq() { grep -v '/api/flags/' "$REQ" 2>/dev/null | tail -1; }
mu()      { printf '%s' "$1" | awk '{print $1" "$2}'; }
rbody()   { printf '%s' "$1" | cut -d' ' -f3-; }
npr()     { grep -c '/api/pr-' "$REQ" 2>/dev/null || true; }

echo "== S1. pr_gate_event_put sends the gate body =="
reset
OUT=$(drv "pr_gate_event_put o/r 7 'ci_green_sha@aaa1111' webhook ci_green_sha=aaa1111 held=0"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1: rc=$RC (want 0)"
[ -z "$OUT" ] && ok || bad "S1: must print nothing, got '$OUT'"
L=$(lastreq)
[ "$(mu "$L")" = "POST http://jobs.test/api/pr-state-events" ] && ok || bad "S1: wrong method/path: $(mu "$L")"
rbody "$L" | jq -e '. == {repo:"o/r",number:7,state:"gate",since:"ci_green_sha@aaa1111",
  reason:"webhook",actor:"testbox",ci_green_sha:"aaa1111",held:0}' >/dev/null 2>&1 \
  && ok || bad "S1: body wrong: $(rbody "$L")"
rbody "$L" | jq -e '(.held|type) == "number"' >/dev/null 2>&1 && ok || bad "S1: held must be a JSON number"

# A head-only event still says state:'gate' — that is what routes it.
reset
drv "pr_gate_event_put o/r 7 'head@bbb2222' webhook head=bbb2222 lead_verdict_word=MERGE" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1b: rc=$RC"
rbody "$(lastreq)" | jq -e '.state == "gate" and .head == "bbb2222" and .lead_verdict_word == "MERGE"' >/dev/null 2>&1 \
  && ok || bad "S1b: body wrong: $(rbody "$(lastreq)")"

echo "== S2. a bad call is rc 1 and sends nothing =="
for code in "pr_gate_event_put o/r 7 src why foo=1" \
            "pr_gate_event_put o/r 7 src why held=2" \
            "pr_gate_event_put o/r 7 src why draft=yes" \
            "pr_gate_event_put o/r 7 src why ci_green_sha" \
            "pr_gate_event_put o/r seven src why held=1" \
            "pr_gate_event_put o/r 7 '' why held=1" \
            "pr_gate_event_put o/r 7 src '' held=1"; do
  reset
  drv "$code" >/dev/null; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "S2: '$code' rc=$RC (want 1)"
  [ "$(npr)" = 0 ] && ok || bad "S2: '$code' sent a request: $(cat "$REQ")"
done

echo "== S3. pr_gate_facts prints the JSON verbatim =="
reset
FACTS='{"rows":[{"repo":"o/r","number":7,"head":"aaa1111","held":null}],"as_of":"2026-10-06T00:00:00Z"}'
OUT=$(CURL_BODY="$FACTS" drv "pr_gate_facts o/r"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3: rc=$RC"
[ "$OUT" = "$FACTS" ] && ok || bad "S3: out='$OUT'"
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-state/gate?repo=o%2Fr" ] && ok \
  || bad "S3: wrong request: $(lastreq)"
reset
OUT=$(CURL_STATUS=404 CURL_BODY='{"error":"not found"}' drv "pr_gate_facts o/r"); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "S3: 404 rc=$RC out='$OUT' (want 1, empty)"

echo "== S4. pr_needs_review prints TSV at rc 0 =="
reset
ROWS='{"rows":[{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","head":"aaa1111","hotfix":0,"nudged":1,"approved_at":"2026-10-06T01:00:00Z"},{"repo":"o/r","number":9,"url":"https://github.com/o/r/pull/9","head":"ccc3333","hotfix":1,"nudged":0,"approved_at":null}],"as_of":"x"}'
OUT=$(CURL_BODY="$ROWS" drv "pr_needs_review o/r"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S4: rc=$RC"
WANT=$(printf '7\taaa1111\thttps://github.com/o/r/pull/7\t0\t1\t2026-10-06T01:00:00Z\n9\tccc3333\thttps://github.com/o/r/pull/9\t1\t0\t-')
[ "$OUT" = "$WANT" ] && ok || bad "S4: out=$(printf '%q' "$OUT")"
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-state/needs-review?repo=o%2Fr" ] && ok \
  || bad "S4: wrong request: $(lastreq)"

echo "== S5. an empty list is rc 2 =="
reset
OUT=$(CURL_BODY='{"rows":[],"as_of":"x"}' drv "pr_needs_review o/r"); RC=$?
[ "$RC" -eq 2 ] && ok || bad "S5: rc=$RC (want 2)"
[ -z "$OUT" ] && ok || bad "S5: out='$OUT'"

echo "== S6. outages are rc 1 and print nothing =="
for spec in "500|{\"error\":\"boom\"}|ok" "404|{\"error\":\"not found\"}|ok" "200|{}|down" "200|{\"ok\":true}|ok" "200|{\"rows\":{}}|ok"; do
  st="${spec%%|*}"; rest="${spec#*|}"; bd="${rest%|*}"; md="${rest##*|}"
  reset
  OUT=$(CURL_STATUS="$st" CURL_BODY="$bd" CURL_MODE="$md" drv "pr_needs_review o/r"); RC=$?
  [ "$RC" -eq 1 ] && ok || bad "S6: status=$st body=$bd mode=$md rc=$RC (want 1)"
  [ -z "$OUT" ] && ok || bad "S6: status=$st mode=$md printed '$OUT'"
done
reset
drv "pr_needs_review ''" >/dev/null; RC=$?
[ "$RC" -eq 1 ] && [ "$(npr)" = 0 ] && ok || bad "S6: empty repo rc=$RC sent=$(npr)"

echo "== S7. not gated on the pr-state-rows flag =="
rm -f "$H/flags/pr-state-rows"
reset
drv "pr_gate_event_put o/r 7 src why held=1" >/dev/null
CURL_BODY='{"rows":[]}' drv "pr_gate_facts o/r" >/dev/null
CURL_BODY='{"rows":[]}' drv "pr_needs_review o/r" >/dev/null
[ "$(npr)" = 3 ] && ok || bad "S7: want 3 /api/pr- requests with the flag down, got $(npr): $(cat "$REQ")"

echo "== worker half (node:test) =="
if command -v node >/dev/null && node -e "require('node:sqlite')" 2>/dev/null \
   && [ -f "$DIR/catalog/lanes.json" ]; then
  [ -f "$DIR/worker/jobs/src/lib/pr-gate.js" ] || bad "pr-gate.js missing"
  if (cd "$DIR/worker/jobs" && node --test test/pr-state-needs-review.test.js >"$T/node.out" 2>&1); then
    ok
  else
    bad "worker/jobs/test/pr-state-needs-review.test.js failed"; grep -E '^not ok' "$T/node.out"
  fi
else
  echo "  (skip: node:sqlite or catalog/lanes.json unavailable; CI's worker job runs it)"
fi

echo "pr-gate-verbs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
