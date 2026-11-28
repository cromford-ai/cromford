#!/bin/bash
# tests/custody-db-down.bh-9554-test.sh — BH-9554 (custody C0): a lane that
# cannot reach the custody database FAILS LOUD. bin/lib/jobs/custody.sh,
# through the REAL jobs client verb `custody` (bin/jobs-client.sh,
# bin/jobs-client.d/bh-9554-custody.sh), against a closed port, an empty
# JOBS_URL, and the REAL worker (tests/lib/custody.bh-9554.mjs) told to answer
# a scripted status. A stub bin/alert-line.sh in the scratch harness records
# its argv. 0 network except 127.0.0.1.
#
#   D1 a closed port: custody claim rc 1, exactly one alert-line call with
#      --id custody-unreachable-<p>, the ticket and the lane in its text
#   D2 an empty JOBS_URL: rc 1, one alert, no curl call
#   D3 a 500: rc 1, one alert
#   D4 a 409: rc 9, zero alerts; a 404: rc 2, zero alerts
#   D5 a 200 whose body has no ok:true: rc 1, one alert
#   D6 three verbs against a closed port: three alert calls, all with the
#      same --id; no file under $HARNESS/state; no ALERTS.log line from the
#      transport (one failure is one alert)
#   D7 no HARNESS_SECRET: rc 1, one alert
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/custody-db-down.bh-9554-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/custody-fixture.bh-9554.sh
. "$(dirname "$0")/lib/custody-fixture.bh-9554.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
custody_fixture_start

# The stub alert helper: one line of argv per call, NUL-free.
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_LOG"
SH
chmod +x "$H/bin/alert-line.sh"
export ALERT_LOG="$T/alerts"
# A curl wrapper that counts calls, then runs the real curl.
REAL_CURL=$(command -v curl)
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<SH
#!/bin/bash
echo call >> "$T/curl-calls"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$T/stub/curl"
export PATH="$T/stub:$PATH"
# A port nothing listens on: bind one, read it, close it.
DEAD=$(node -e "const s=require('net').createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();})")
P=down-p
reset() { : > "$ALERT_LOG"; : > "$T/curl-calls"; }
alerts() { grep -c . "$ALERT_LOG"; }
curls() { grep -c . "$T/curl-calls"; }
answer() { hook PUT /__answer "$1" > /dev/null; }
LIVE="$JOBS_URL"

# ============================================================================
echo "D1: a closed port"
reset
JOBS_URL="http://127.0.0.1:$DEAD" jc custody claim "$P" "$(uniq_key 1)" pool building reoffer
[ "$RC" = 1 ] && ok "D1 rc 1" || bad "D1 rc=$RC out=$(cat "$T/out")"
[ "$(alerts)" = 1 ] && ok "D1 exactly one alert" || bad "D1 alerts: $(cat "$ALERT_LOG")"
grep -q -- "--id custody-unreachable-$P --project $P " "$ALERT_LOG" && ok "D1 --id custody-unreachable-$P" || bad "D1 alert argv: $(cat "$ALERT_LOG")"
grep -q "claim $(uniq_key 1) by pool failed: curl_rc=" "$ALERT_LOG" && ok "D1 the text names the verb, ticket, lane and status" || bad "D1 text: $(cat "$ALERT_LOG")"
grep -q '^custody: ' "$T/err" && ok "D1 one stderr line" || bad "D1 stderr: $(cat "$T/err")"

# ============================================================================
echo "D2: an empty JOBS_URL"
reset
JOBS_URL='' jc custody claim "$P" "$(uniq_key 2)" pool building reoffer
[ "$RC" = 1 ] && [ "$(alerts)" = 1 ] && ok "D2 rc 1, one alert" || bad "D2 rc=$RC alerts=$(cat "$ALERT_LOG")"
[ "$(curls)" = 0 ] && ok "D2 no curl call" || bad "D2 curl calls $(curls)"
grep -q 'failed: no-url' "$ALERT_LOG" && ok "D2 the status word is no-url" || bad "D2 text: $(cat "$ALERT_LOG")"

# ============================================================================
echo "D3: a 500"
reset; answer '{"status":500,"body":"{\"error\":\"boom\"}"}'
jc custody claim "$P" "$(uniq_key 3)" pool building reoffer
[ "$RC" = 1 ] && [ "$(alerts)" = 1 ] && grep -q 'failed: http=500' "$ALERT_LOG" && ok "D3 rc 1, one alert, http=500" || bad "D3 rc=$RC alerts=$(cat "$ALERT_LOG")"

# ============================================================================
echo "D4: a 409 and a 404 are answers, not outages"
reset; answer '{"status":409,"body":"{\"error\":\"held\",\"owner_lane\":\"pool\"}"}'
jc custody claim "$P" "$(uniq_key 4)" triage triaged reoffer
[ "$RC" = 9 ] && [ "$(jq -r .error "$T/out")" = held ] && ok "D4 409: rc 9, the body on stdout" || bad "D4 409 rc=$RC out=$(cat "$T/out")"
answer '{"status":404,"body":"{\"error\":\"no_row\"}"}'
jc custody renew "$P" "$(uniq_key 4)" pool
[ "$RC" = 2 ] && ok "D4 404: rc 2" || bad "D4 404 rc=$RC"
[ "$(alerts)" = 0 ] && ok "D4 zero alerts" || bad "D4 alerts: $(cat "$ALERT_LOG")"

# ============================================================================
echo "D5: a 200 without ok:true"
reset; answer '{"status":200,"body":"{\"rows\":[]}"}'
jc custody claim "$P" "$(uniq_key 5)" pool building reoffer
[ "$RC" = 1 ] && [ "$(alerts)" = 1 ] && grep -q 'body without ok:true' "$ALERT_LOG" && ok "D5 rc 1, one alert" || bad "D5 rc=$RC alerts=$(cat "$ALERT_LOG")"
answer '{"status":200,"body":"not json"}'
reset
jc custody row "$P" "$(uniq_key 5)"
[ "$RC" = 1 ] && [ "$(alerts)" = 1 ] && ok "D5 a 200 that is not JSON: rc 1, one alert" || bad "D5 non-json rc=$RC"
answer '{}'
jc custody claim "$P" "$(uniq_key 5)" pool building reoffer
[ "$RC" = 0 ] && ok "D5 the live worker answers again: rc 0" || bad "D5 live rc=$RC out=$(cat "$T/out")"

# ============================================================================
echo "D6: three verbs against a dead endpoint"
reset
find "$H/state" -type f > "$T/state-before"
# The transport writes its ALERTS.log line once a UTC day, keyed by a flag
# file; clear the flag so a transport line would show here.
scratch_rm "$H/flags";: > "$H/logs/ALERTS.log"
export JOBS_URL="http://127.0.0.1:$DEAD"
K=$(uniq_key 6)
jc custody claim "$P" "$K" pool building reoffer; R1=$RC
jc custody renew "$P" "$K" pool; R2=$RC
jc custody next "$P" "$K" pool wait --deadline-min 10; R3=$RC
export JOBS_URL="$LIVE"
[ "$R1$R2$R3" = 111 ] && ok "D6 every verb rc 1" || bad "D6 rc $R1 $R2 $R3"
[ "$(alerts)" = 3 ] && ok "D6 three alert calls" || bad "D6 alerts: $(cat "$ALERT_LOG")"
[ "$(sed -n 's/^--id \([^ ]*\) .*/\1/p' "$ALERT_LOG" | sort -u)" = "custody-unreachable-$P" ] \
  && ok "D6 all three with one --id" || bad "D6 ids: $(cat "$ALERT_LOG")"
find "$H/state" -type f > "$T/state-after"
cmp -s "$T/state-before" "$T/state-after" && ok "D6 no file written under \$HARNESS/state" || bad "D6 state: $(cat "$T/state-after")"
[ ! -s "$H/logs/ALERTS.log" ] && ok "D6 no transport ALERTS.log line (JOBS_ALERT=0)" || bad "D6 ALERTS.log: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "D7: no HARNESS_SECRET"
reset
HARNESS_SECRET='' jc custody claim "$P" "$(uniq_key 7)" pool building reoffer
[ "$RC" = 1 ] && [ "$(alerts)" = 1 ] && grep -q 'failed: no-secret' "$ALERT_LOG" && [ "$(curls)" = 0 ] \
  && ok "D7 rc 1, one alert, no curl" || bad "D7 rc=$RC alerts=$(cat "$ALERT_LOG") curls=$(curls)"

echo "custody-db-down: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
