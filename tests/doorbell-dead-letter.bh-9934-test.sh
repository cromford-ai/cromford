#!/bin/bash
# tests/doorbell-dead-letter.bh-9934-test.sh — BH-9934: the daily doorbell lane
# ("$DIR/bin/doorbell-coverage-check.sh") reads
# GET /api/webhook-dead-letters?vendor=github and fires ONE alert while the
# dead-letter count is above 0, then resolves it when the count is back at 0.
#
# The worker answer is the shape worker/jobs/test/webhook-receiver.bh-9934 D1
# asserts on the real route: {vendor, count, newest_at, newest:{delivery_id,
# event, error}|null, as_of}.
#   1 count 2 -> 1 ALERTS line and 1 fleet_alert beat, akey webhook-dead-letter:github
#   2 a second run at count 2 -> 0 new lines, 0 new beats
#   3 count 0 -> the flag is gone and the console resolve is called once
#   4 worker 500 -> 0 alerts, the LOG says `failed`, never `count=0`; the flag stays
#   5 a --repo run makes 0 dead-letter reads
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/doorbell-dead-letter.bh-9934-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/bin/doorbell-coverage-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SUT" ] || { echo "FAIL: bin/doorbell-coverage-check.sh missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

export JOBS_URL="https://jobs.test" HARNESS_SECRET=s JOBS_RETRIES=0
export HARNESS="$T/harness" HARNESS_ALERTS="$T/harness/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/flags" "$HARNESS/env" "$T/calls" "$T/fakebin"
printf 'CONSOLE_URL=https://console.test\nHARNESS_SECRET=s\n' > "$HARNESS/env/global.env"
export CALLS="$T/calls" DL_JSON="$T/dl.json" DL_500="$T/dl.500"
export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<EOF2
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
armed-proj    Test/armed      -  -  1  box-test 100.0.0.1
EOF2

printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
# The beat stand-in records each beat's JSON.
cat > "$T/fakebin/beat" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CALLS/beats"
SH
chmod +x "$T/fakebin/beat"
export DOORBELL_BEAT="$T/fakebin/beat"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/webhook-dead-letters"*)
    echo "${!#}" >> "$CALLS/dl"
    if [ -f "$DL_500" ]; then printf '{"error":"boom"}\n500'; exit 0; fi
    printf '%s\n200' "$(cat "$DL_JSON")"; exit 0 ;;
  *"console.test/api/alerts/open"*)
    echo open >> "$CALLS/resolve-open"
    printf '{"alerts":[{"id":9,"akey":"webhook-dead-letter:github"}]}'; exit 0 ;;
  *"console.test/api/alerts/resolve"*)
    echo post >> "$CALLS/resolve-post"; printf '200'; exit 0 ;;
  *"/api/wakes/cursor?all=1"*)
    printf '{"cursors":[]}\n200'; exit 0 ;;
  *"/api/wakes/prune"*)
    printf '{"deleted":0,"before":"2026-09-15T00:00:00Z","capped":false}\n200'; exit 0 ;;
  *"/api/wakes/summary"*)
    printf '{"repos":[{"repo":"Test/armed","last_id":7,"last_at":"2026-11-24T05:00:00Z","kinds":"pr"}]}\n200'; exit 0 ;;
esac
printf '{}\n200'
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

dl() { # dl <count>
  if [ "$1" = 0 ]; then
    printf '{"vendor":"github","count":0,"newest_at":null,"newest":null,"as_of":"2026-11-24T06:00:00Z"}' > "$DL_JSON"
  else
    printf '{"vendor":"github","count":%s,"newest_at":"2026-11-24T05:59:00Z","newest":{"delivery_id":"dlv-42","event":"pull_request","error":"D1_ERROR: overloaded"},"as_of":"2026-11-24T06:00:00Z"}' "$1" > "$DL_JSON"
  fi
}
FLAG="$HARNESS/flags/webhook-dead-letter-github"
cnt() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
dl_alerts() { grep -c '\[doorbell\] .*dead-letter' "$HARNESS_ALERTS" 2>/dev/null; return 0; }
dl_beats() { [ -f "$CALLS/beats" ] && grep -c '"akey":"webhook-dead-letter:github"' "$CALLS/beats"; [ -f "$CALLS/beats" ] || echo 0; }
lanelog() { cat "$HARNESS/logs/doorbell-coverage-check.log" 2>/dev/null; }
run() { OUT=$("$SUT" "$@" 2>&1); RC=$?; }
: > "$HARNESS_ALERTS"

# ── 1. count 2 -> one alert line and one beat ──
dl 2; run
[ "$RC" = 0 ] && ok || bad "1 rc=$RC: $OUT"
[ "$(cnt "$CALLS/dl")" = 1 ] && ok || bad "1 want one dead-letter read, got $(cnt "$CALLS/dl")"
[ "$(dl_alerts)" = 1 ] && ok || bad "1 want 1 dead-letter alert, got $(dl_alerts): $(cat "$HARNESS_ALERTS")"
grep -q 'holds 2 dead-letter .*dlv-42.*event pull_request.*D1_ERROR: overloaded' "$HARNESS_ALERTS" && ok \
  || bad "1 the line lacks the count, id, event or error: $(cat "$HARNESS_ALERTS")"
grep -q 'redeliver' "$HARNESS_ALERTS" && ok || bad "1 the line names no fix"
[ "$(dl_beats)" = 1 ] && ok || bad "1 want 1 beat with the akey, got $(dl_beats): $(cat "$CALLS/beats" 2>/dev/null)"
[ -f "$FLAG" ] && ok || bad "1 the flag was not created"
grep -q 'dead-letters vendor=github count=2' <<<"$(lanelog)" && ok || bad "1 no count LOG line: $(lanelog)"
case "$OUT" in *"checked=1 missing=0 unreadable=0 ringing=1"*) ok ;; *) bad "1 the summary line changed — $OUT" ;; esac

# ── 2. a second run at count 2 -> nothing new ──
run
[ "$(cnt "$CALLS/dl")" = 2 ] && ok || bad "2 the second run did not read"
[ "$(dl_alerts)" = 1 ] && ok || bad "2 a second run re-alerted: $(dl_alerts)"
[ "$(dl_beats)" = 1 ] && ok || bad "2 a second run beat again: $(dl_beats)"

# ── 4. a worker 500 -> no alert, `failed`, never count=0; the flag stays ──
: > "$DL_500"; : > "$HARNESS/logs/doorbell-coverage-check.log"
run
[ "$RC" = 0 ] && ok || bad "4 rc=$RC"
[ "$(dl_alerts)" = 1 ] && ok || bad "4 a failed read alerted: $(cat "$HARNESS_ALERTS")"
grep -q 'dead-letters check failed' <<<"$(lanelog)" && ok || bad "4 no failed LOG line: $(lanelog)"
grep -q 'count=0' <<<"$(lanelog)" && bad "4 a failed read logged count=0: $(lanelog)" || ok
[ -f "$FLAG" ] && ok || bad "4 a failed read removed the flag"
[ "$(cnt "$CALLS/resolve-open")" = 0 ] && ok || bad "4 a failed read resolved the alert"
rm -f "$DL_500"

# ── 3. count 0 -> flag removed, resolve once ──
dl 0; run
[ ! -f "$FLAG" ] && ok || bad "3 the flag is still there"
[ "$(cnt "$CALLS/resolve-open")" = 1 ] && ok || bad "3 want one resolve read, got $(cnt "$CALLS/resolve-open")"
[ "$(cnt "$CALLS/resolve-post")" = 1 ] && ok || bad "3 want one resolve POST, got $(cnt "$CALLS/resolve-post")"
grep -q 'dead-letters vendor=github count=0' <<<"$(lanelog)" && ok || bad "3 no count=0 LOG line: $(lanelog)"
run
[ "$(cnt "$CALLS/resolve-open")" = 1 ] && ok || bad "3 a second run at 0 resolved again"
# and a new dead letter alerts again
dl 1; run
[ "$(dl_alerts)" = 2 ] && ok || bad "3 a count back above 0 must alert again: $(dl_alerts)"

# ── 5. a --repo run makes no dead-letter read ──
B=$(cnt "$CALLS/dl")
run --repo Test/armed
[ "$(cnt "$CALLS/dl")" = "$B" ] && ok || bad "5 a --repo run read the dead letters"

echo "doorbell-dead-letter.bh-9934: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
