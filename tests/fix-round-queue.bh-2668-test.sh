#!/bin/bash
# tests/fix-round-queue.bh-2668-test.sh — BH-2668 (BH-2530.0): the fix-round
# queue's shell client, bin/lib/fix-round-queue.sh, over the REAL _jobs_req.
#
# Copies the checkout's bin/jobs-client.sh and bin/lib/jobs/*.sh into a scratch
# harness, sources the real lib after it, and puts a curl shim first on PATH.
# The shim logs `METHOD URL` and the body (reading @file when given) and answers
# from $T/ans/<n> (body), $T/ans/<n>.code (HTTP status, default 200) and
# $T/ans/<n>.rc (a non-zero curl exit), n being the call ordinal. So every
# request below is the one production sends, through production's transport.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-queue.bh-2668-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fix-round-queue.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/fakebin" "$T/ans"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
T="$T"
EOF
cat >> "$T/fakebin/curl" <<'EOF'
method=GET body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=$(( $(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/n"
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s %s\n' "$method" "$url" >> "$T/curl.log"
printf '%s' "$body" > "$T/body.$n"
[ -f "$T/ans/$n.rc" ] && exit "$(cat "$T/ans/$n.rc")"
[ -f "$T/ans/$n" ] && cat "$T/ans/$n"
printf '\n%s' "$(cat "$T/ans/$n.code" 2>/dev/null || echo 200)"
EOF
chmod +x "$T/fakebin/curl"

URL=https://jobs.invalid
run() {
  ( export HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL="$URL" JOBS_BOX=testbox JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0
    export PATH="$T/fakebin:$PATH"
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$LIB" || exit 99
    "$@" )
}
reset() { rm -rf "$T/ans" "$T/curl.log" "$T"/body.* "$T/n" "$T/h/logs"; mkdir -p "$T/ans"; }
ans() { printf '%s' "$2" > "$T/ans/$1"; printf '%s' "${3:-200}" > "$T/ans/$1.code"; }
calls() { [ -f "$T/curl.log" ] && wc -l < "$T/curl.log" || echo 0; }
JOB='{"id":7,"project":"p","cap_key":"ck","box":"b1","status":"queued"}'

# --- S0. sourcing prints nothing and creates no file ------------------------
reset
BEFORE=$(find "$T" | sort)
OUT=$( ( export HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL="$URL"
         . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1; . "$LIB" ) 2>&1 ); RC=$?
AFTER=$(find "$T" | sort)
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$BEFORE" = "$AFTER" ] && ok || bad "S0: source rc=$RC out='$OUT' files changed=$([ "$BEFORE" = "$AFTER" ] && echo no || echo yes)"

# --- S1. enqueue 201 --------------------------------------------------------
reset
ans 1 "{\"job\":$JOB}" 201
OUT=$(run fix_round_enqueue p ck b1 1 '{"k":"v"}' p rk 'a "quoted" reason' https://u rec tk); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -c . <<<"$OUT")" = "$(jq -c . <<<"$JOB")" ] && ok || bad "S1: rc=$RC out='$OUT'"
[ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds" ] && ok || bad "S1: request '$(sed -n 1p "$T/curl.log")'"
B="$T/body.1"
jq -e '.project=="p" and .cap_key=="ck" and .box=="b1" and .hotfix==1 and (.hotfix|type)=="number"
       and .args==["p","rk","a \"quoted\" reason","https://u","rec","tk"]
       and .record_in=="{\"k\":\"v\"}"' "$B" >/dev/null && ok || bad "S1: body $(cat "$B")"
# An empty record is JSON null, not "".
reset
ans 1 "{\"job\":$JOB}" 201
run fix_round_enqueue p ck b1 0 '' a b c d e f >/dev/null; RC=$?
[ "$RC" -eq 0 ] && jq -e '.record_in==null and .hotfix==0' "$T/body.1" >/dev/null && ok || bad "S1: empty record rc=$RC body $(cat "$T/body.1" 2>/dev/null)"
# Bad input: no request.
reset
for argv in "p ck b1 2 {} a b c d e f" "p ck b1 1 {} a b c d e" "p  b1 1 {} a b c d e f"; do
  # shellcheck disable=SC2086
  run fix_round_enqueue $argv >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 1 ] || bad "S1: bad input '$argv' rc=$RC"
done
run fix_round_enqueue p '' b1 1 '{}' a b c d e f >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && [ "$(calls)" -eq 0 ] && ok || bad "S1: bad input made $(calls) requests, rc=$RC"

# --- S2. duplicate answer is rc 0 with duplicate:true -----------------------
reset
ans 1 "{\"duplicate\":true,\"job\":$JOB}" 200
OUT=$(run fix_round_enqueue p ck b1 0 '{}' a b c d e f); RC=$?
[ "$RC" -eq 0 ] && jq -e '.duplicate==true and .id==7' <<<"$OUT" >/dev/null && ok || bad "S2: rc=$RC out='$OUT'"
# A 2xx without a .job is not a success.
reset
ans 1 'oops' 200
OUT=$(run fix_round_enqueue p ck b1 0 '{}' a b c d e f); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "S2: non-JSON 200 rc=$RC out='$OUT'"

# --- S3. 503 and transport failure are rc 1 ---------------------------------
reset
ans 1 '{"error":"down"}' 503
OUT=$(run fix_round_enqueue p ck b1 0 '{}' a b c d e f); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "S3: 503 rc=$RC out='$OUT'"
reset
echo 7 > "$T/ans/1.rc"
run fix_round_enqueue p ck b1 0 '{}' a b c d e f >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S3: transport rc=$RC"

# --- S4. a 300 KB record answered 413: rc 1, logged, never truncated --------
reset
BIG=$(head -c 300000 /dev/zero | tr '\0' 'x' | jq -Rsc '{blob:.}')
ans 1 '{"error":"too large"}' 413
run fix_round_enqueue p ck-big b1 0 "$BIG" a b c d e f >/dev/null 2>&1; RC=$?
LOG="$T/h/logs/jobs-client.log"
[ "$RC" -eq 1 ] && ok || bad "S4: rc=$RC"
grep -q 'fix_round_enqueue p ck-big: 413' "$LOG" 2>/dev/null && ok || bad "S4: no 413 line naming the cap_key in jobs-client.log: $(cat "$LOG" 2>/dev/null)"
SZ=$(wc -c < "$T/body.1")
[ "$SZ" -gt 300000 ] && [ "$(jq -r .record_in "$T/body.1")" = "$BIG" ] && ok || bad "S4: body arrived as $SZ bytes"

# --- S5. 404 on enqueue is rc 1, not 2 --------------------------------------
reset
ans 1 '' 404
run fix_round_enqueue p ck b1 0 '{}' a b c d e f >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S5: 404 rc=$RC"
grep -q 'POST /api/fix-rounds 404: worker predates the fix-round routes' "$T/h/logs/jobs-client.log" 2>/dev/null && ok || bad "S5: no 404 log line"

# --- S6. get returns the open-or-done row, never adopted or foreign ---------
reset
ans 1 '{"fix_round_jobs":[{"id":1,"cap_key":"c/k&1","status":"adopted"},{"id":2,"cap_key":"c/k&1","status":"done"},{"id":3,"cap_key":"other","status":"queued"}]}'
OUT=$(run fix_round_get 'p/x' 'c/k&1'); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .id <<<"$OUT")" = 2 ] && ok || bad "S6: rc=$RC out='$OUT'"
[ "$(sed -n 1p "$T/curl.log")" = "GET $URL/api/fix-rounds?project=p%2Fx&cap_key=c%2Fk%261&limit=500" ] && ok || bad "S6: url '$(sed -n 1p "$T/curl.log")'"
reset
ans 1 '{"fix_round_jobs":[{"id":1,"cap_key":"ck","status":"adopted"}]}'
OUT=$(run fix_round_get p ck); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "S6: adopted-only rc=$RC out='$OUT'"
reset
ans 1 '{"fix_round_jobs":[{"id":3,"cap_key":"other","status":"queued"}]}'
OUT=$(run fix_round_get p ck); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "S6: foreign-only rc=$RC out='$OUT'"
reset
ans 1 '{"fix_round_jobs":[]}'
run fix_round_get p ck >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "S6: empty rc=$RC"

# --- S7. get: 404 → 2, 500 → 1, non-JSON 200 → 1 ---------------------------
for pair in "404:2" "500:1"; do
  reset; ans 1 '' "${pair%%:*}"
  run fix_round_get p ck >/dev/null; RC=$?
  [ "$RC" -eq "${pair##*:}" ] && ok || bad "S7: ${pair%%:*} rc=$RC"
done
reset; ans 1 'oops' 200
run fix_round_get p ck >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S7: non-JSON 200 rc=$RC"

# --- S8. claim --------------------------------------------------------------
reset; ans 1 "{\"job\":$JOB}" 200
OUT=$(run fix_round_claim b1 7); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .id <<<"$OUT")" = 7 ] && ok || bad "S8: 200 rc=$RC out='$OUT'"
[ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds/claim" ] && jq -e '.box=="b1" and .stale_min==7' "$T/body.1" >/dev/null && ok || bad "S8: body $(cat "$T/body.1")"
reset; ans 1 "{\"job\":$JOB}" 200
run fix_round_claim b1 x >/dev/null; RC=$?
jq -e 'has("stale_min")|not' "$T/body.1" >/dev/null && ok || bad "S8: stale_min=x sent: $(cat "$T/body.1")"
for pair in "404:2" "409:9" "500:1"; do
  reset; ans 1 '{}' "${pair%%:*}"
  run fix_round_claim b1 >/dev/null; RC=$?
  [ "$RC" -eq "${pair##*:}" ] && ok || bad "S8: ${pair%%:*} rc=$RC"
done
reset; ans 1 '{}' 200
run fix_round_claim b1 >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S8: 200 without job rc=$RC"

# --- S9. finish -------------------------------------------------------------
reset; ans 1 '{"ok":true}' 200
run fix_round_finish 7 b1 'OK pushed' >/dev/null; RC=$?
[ "$RC" -eq 0 ] && jq -e '.id==7 and (.id|type)=="number" and .box=="b1" and .result=="OK pushed" and (has("record_out")|not)' "$T/body.1" >/dev/null \
  && [ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds/finish" ] && ok || bad "S9: 200 rc=$RC body $(cat "$T/body.1")"
reset; ans 1 '{"ok":true}' 200
run fix_round_finish 7 b1 OK '{"r":1}' >/dev/null
jq -e '.record_out=="{\"r\":1}"' "$T/body.1" >/dev/null && ok || bad "S9: record_out body $(cat "$T/body.1")"
for pair in "409:9" "400:1" "404:1" "500:1"; do
  reset; ans 1 '{}' "${pair%%:*}"
  run fix_round_finish 7 b1 OK >/dev/null; RC=$?
  [ "$RC" -eq "${pair##*:}" ] && ok || bad "S9: ${pair%%:*} rc=$RC"
done
reset
run fix_round_finish x7 b1 OK >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && [ "$(calls)" -eq 0 ] && ok || bad "S9: non-numeric id rc=$RC calls=$(calls)"

# --- S10. adopt -------------------------------------------------------------
reset; ans 1 '{"job":{"id":7,"status":"adopted"}}' 200
OUT=$(run fix_round_adopt 7); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .status <<<"$OUT")" = adopted ] && jq -e '.id==7' "$T/body.1" >/dev/null \
  && [ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds/adopt" ] && ok || bad "S10: 200 rc=$RC out='$OUT'"
for pair in "409:9" "500:1" "404:1"; do
  reset; ans 1 '{}' "${pair%%:*}"
  run fix_round_adopt 7 >/dev/null; RC=$?
  [ "$RC" -eq "${pair##*:}" ] && ok || bad "S10: ${pair%%:*} rc=$RC"
done

# --- S11. open_count = queued + claimed; outage prints nothing --------------
reset
ans 1 '{"fix_round_jobs":[{"id":1,"status":"queued"},{"id":2,"status":"queued"}]}'
ans 2 '{"fix_round_jobs":[{"id":3,"status":"claimed"}]}'
OUT=$(run fix_round_open_count); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = 3 ] && ok || bad "S11: rc=$RC out='$OUT'"
[ "$(sed -n 1p "$T/curl.log")" = "GET $URL/api/fix-rounds?status=queued&limit=500" ] \
  && [ "$(sed -n 2p "$T/curl.log")" = "GET $URL/api/fix-rounds?status=claimed&limit=500" ] && ok || bad "S11: urls $(cat "$T/curl.log")"
reset
ans 1 '{"fix_round_jobs":[{"id":1,"status":"queued"}]}'
ans 2 '{}' 500
OUT=$(run fix_round_open_count); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "S11: outage rc=$RC out='$OUT'"
reset
ans 1 '{"fix_round_jobs":[]}'
ans 2 'oops'
OUT=$(run fix_round_open_count); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "S11: non-list rc=$RC out='$OUT'"

# --- S12. not configured: rc 1, one line, no request ------------------------
reset
ERR=$( ( export HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL="" PATH="$T/fakebin:$PATH"
         . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1; . "$LIB"; fix_round_claim b1 ) 2>&1 >/dev/null ); RC=$?
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] && [ -n "$ERR" ] && [ "$(calls)" -eq 0 ] && ok || bad "S12: empty JOBS_URL rc=$RC err='$ERR' calls=$(calls)"
reset
ERR=$( ( export HARNESS="$T/h" JOBS_URL="$URL" PATH="$T/fakebin:$PATH"; unset HARNESS_SECRET
         . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1; . "$LIB"; fix_round_open_count ) 2>&1 >/dev/null ); RC=$?
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] && [ -n "$ERR" ] && [ "$(calls)" -eq 0 ] && ok || bad "S12: no secret rc=$RC err='$ERR' calls=$(calls)"
[ ! -f "$T/h/logs/ALERTS.log" ] && ok || bad "S12: not-configured wrote an ALERTS line"

# --- S13. the lib is not a JC_MODULES module --------------------------------
JCM=$(grep -m1 '^JC_MODULES=' "$DIR/bin/jobs-client.sh")
[ -n "$JCM" ] && case "$JCM" in *fix-round*) false ;; *) true ;; esac && ok || bad "S13: JC_MODULES line '$JCM'"

# --- S14. the schema block is additive and carries the RLS note -------------
BLOCK=$(awk '/^-- ── BH-2668/{on=1} on&&/^-- ── /&&!/BH-2668/{exit} on' "$DIR/worker/jobs/schema.sql")
[ -n "$BLOCK" ] && ok || bad "S14: no BH-2668 block in schema.sql"
grep -Eq '^(DROP|ALTER)' <<<"$BLOCK" && bad "S14: destructive statement in the block" || ok
grep -q 'D1 has no RLS' <<<"$BLOCK" && ok || bad "S14: no RLS note"
grep -q '^CREATE TABLE IF NOT EXISTS fix_round_jobs (' <<<"$BLOCK" && ok || bad "S14: no CREATE TABLE in the block"

# --- S15. a failing verb under set -euo pipefail does not kill the caller ---
reset; ans 1 '{}' 500
OUT=$( ( set -euo pipefail
         export HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL="$URL" JOBS_RETRIES=0 PATH="$T/fakebin:$PATH"
         . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1; . "$LIB"
         rc=0; fix_round_open_count >/dev/null || rc=$?; echo "alive rc=$rc" ) 2>/dev/null )
[ "$OUT" = "alive rc=1" ] && ok || bad "S15: strict-mode caller got '$OUT'"

echo "fix-round-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
