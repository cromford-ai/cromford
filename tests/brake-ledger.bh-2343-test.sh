#!/bin/bash
# tests/brake-ledger.bh-2343-test.sh — BH-2343 (BH-2316.0): bin/lib/brake-ledger.sh,
# the durable copy of the three paid alert lanes' "already paid" brakes.
#
# Sources the checkout's real bin/jobs-client.sh (and its bin/lib/jobs modules)
# and then the real library, and replaces ONLY _jobs_req with a stub worker that
# logs `METHOD PATH BODY` and answers from a file-backed ledger or from scripted
# pages. job_ledger_put and ledger_page run for real, so the request lines below
# are the ones production sends.
#
#   1  mark -> read round trip (PUT body, TSV row)
#   2  window filter drops a row older than max_age
#   3  a cleared row is absent; brake_clear sends status cleared
#   4  outage: non-JSON 200, rc 1, and a page-2 failure are rc 1 with NO rows
#   5  a full page walks `before=<last updated_at>&before_key=<last key>`
#      (BH-2450) and prints both pages
#   6  5 full in-window pages -> 5 requests, `#truncated` last, rc 0;
#      an out-of-window 5th page stops without `#truncated`
#   7  only _jobs_req is reached: no ssh, no curl, no /api/boxes
#   8  invalid input makes no request
#   9  brake_db_on delegates to alerts_db_on
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/brake-ledger.bh-2343-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/h/flags" "$T/fakebin" "$T/pages"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/h/bin/lib/alert-state.sh"

# Anything that is not _jobs_req leaving the process is recorded here.
for b in ssh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/sink.%s"\nexit 0\n' "$b" "$T" "$b" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done

NOW=1790000000
export BRAKE_NOW=$NOW
NOW_ISO=$(jq -nr --argjson n "$NOW" '$n|todate')

# stub_env — the body every case runs in. A PUT is stored in store.jsonl with
# updated_at=NOW_ISO. A GET list answers pages/<n> (n = the GET's ordinal in
# this case) when that file exists, with rc from pages/<n>.rc; otherwise it
# answers the stored rows. STUB_DOWN=1 makes every request rc 1.
run() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=testbox
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/brake-ledger.sh" || exit 99
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/req.log"
      [ "${STUB_DOWN:-0}" = 1 ] && return 1
      case "$1 $2" in
        "PUT /api/ledger")
          printf '%s' "$3" | jq -c --arg t "$NOW_ISO" '. + {updated_at:$t}' >> "$T/store.jsonl"
          printf '{"ledger":{}}'; return 0 ;;
        "GET /api/ledger?"*)
          local n; n=$(grep -c '^GET ' "$T/req.log")
          if [ -f "$T/pages/$n" ]; then
            cat "$T/pages/$n"
            [ -f "$T/pages/$n.rc" ] && return "$(cat "$T/pages/$n.rc")"
            return 0
          fi
          jq -sc '{ledgers: ., as_of: "x"}' "$T/store.jsonl" 2>/dev/null || printf '{"ledgers":[]}'
          return 0 ;;
      esac
      return 2
    }
    "$@" )
}
reset() { rm -f "$T/req.log" "$T/store.jsonl" "$T"/pages/* "$T"/sink.*; }
reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log" | tr -d ' '; else echo 0; fi; }
TAB=$(printf '\t')

# page <file> <count> <first-age> [status] — <count> rows, row i aged first-age+i
# seconds, updated_at == detail.at, sorted updated_at DESC like the worker.
page() {
  jq -nc --argjson now "$NOW" --argjson c "$2" --argjson a0 "$3" --arg st "${4:-set}" \
    '{ledgers: [range($c) as $i | ($now - $a0 - $i) as $at
       | {kind:"brake:triage-family", key:"k\($a0 + $i)", status:$st,
          detail:({at:$at}|tojson), updated_at:($at|todate)}], as_of:"x"}' > "$1"
}

# --- 1. mark -> read round trip ----------------------------------------------
reset
run brake_mark triage-family fam-a "$NOW" '{"n":2}'; RC=$?
LINE=$(head -1 "$T/req.log" 2>/dev/null)
BODY=${LINE#PUT /api/ledger }
if [ "$RC" -eq 0 ] && [ "${LINE%% *}" = "PUT" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.kind')" = "brake:triage-family" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.key')" = "fam-a" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.status')" = "set" ] \
   && [ "$(printf '%s' "$BODY" | jq -c '.detail|fromjson')" = "{\"n\":2,\"at\":$NOW}" ]; then ok
else bad "brake_mark rc=$RC request '$LINE'"; fi
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "fam-a${TAB}${NOW}${TAB}{\"n\":2,\"at\":$NOW}" ] \
  && ok || bad "round trip read rc=$RC out='$OUT'"
GET=$(grep '^GET ' "$T/req.log")
[ "$GET" = "GET /api/ledger?kind=brake%3Atriage-family&limit=1000 " ] \
  && ok || bad "first read request was '$GET'"
# detail's `at` always wins over a caller-supplied `at`
reset
run brake_mark triage-family fam-b "$NOW" '{"at":5,"x":"y"}'
[ "$(sed 's/^PUT \/api\/ledger //' "$T/req.log" | jq -c '.detail|fromjson')" = "{\"at\":$NOW,\"x\":\"y\"}" ] \
  && ok || bad "caller at overrode epoch: $(cat "$T/req.log")"
# no detail -> {"at":epoch}
reset
run brake_mark medic-seen s1 "$NOW"; RC=$?
[ "$RC" -eq 0 ] && [ "$(sed 's/^PUT \/api\/ledger //' "$T/req.log" | jq -c '.detail|fromjson')" = "{\"at\":$NOW}" ] \
  && ok || bad "brake_mark without detail rc=$RC: $(cat "$T/req.log")"
# the transport rc is returned verbatim
reset
STUB_DOWN=1 run brake_mark medic-seen s1 "$NOW"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "brake_mark on outage rc=$RC, wanted 1"

# --- 2. window filter ---------------------------------------------------------
reset
jq -nc --argjson now "$NOW" '{ledgers:[
  {kind:"brake:triage-family",key:"fresh",status:"set",detail:({at:($now-60)}|tojson),updated_at:(($now-60)|todate)},
  {kind:"brake:triage-family",key:"old",status:"set",detail:({at:($now-7200)}|tojson),updated_at:(($now-7200)|todate)}]}' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "fresh${TAB}$((NOW-60))${TAB}{\"at\":$((NOW-60))}" ] \
  && ok || bad "window filter rc=$RC out='$OUT'"

# --- 3. cleared rows are absent ----------------------------------------------
reset
run brake_clear triage-family fam-a; RC=$?
BODY=$(sed 's/^PUT \/api\/ledger //' "$T/req.log")
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$BODY" | jq -r '.status')" = "cleared" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.kind')" = "brake:triage-family" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.key')" = "fam-a" ] \
  && ok || bad "brake_clear rc=$RC body '$BODY'"
reset
jq -nc --argjson now "$NOW" '{ledgers:[
  {kind:"brake:triage-family",key:"gone",status:"cleared",detail:({at:($now-10)}|tojson),updated_at:(($now-10)|todate)},
  {kind:"brake:triage-family",key:"held",status:"set",detail:({at:($now-20)}|tojson),updated_at:(($now-20)|todate)}]}' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "held${TAB}$((NOW-20))${TAB}{\"at\":$((NOW-20))}" ] \
  && ok || bad "cleared row leaked: rc=$RC out='$OUT'"

# --- 4. outage is rc 1 and NO rows -------------------------------------------
reset
printf '<html>502</html>' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "non-JSON 200 gave rc=$RC out='$OUT'"
reset
printf '{"error":"x"}' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "JSON without .ledgers gave rc=$RC out='$OUT'"
reset
OUT=$(STUB_DOWN=1 run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "_jobs_req rc 1 gave rc=$RC out='$OUT'"
reset
page "$T/pages/1" 1000 0
: > "$T/pages/2"; echo 1 > "$T/pages/2.rc"
OUT=$(run brake_read triage-family 100000); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && [ "$(reqs)" -eq 2 ] \
  && ok || bad "page-2 failure after a good page 1 gave rc=$RC, $(printf '%s\n' "$OUT" | grep -c .) rows, $(reqs) requests"
# an empty ledger is an answer: rc 0, nothing printed
reset
printf '{"ledgers":[]}' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "empty ledger gave rc=$RC out='$OUT'"

# --- 5. more than one page walks `before` ------------------------------------
reset
page "$T/pages/1" 1000 0
page "$T/pages/2" 3 1000
OUT=$(run brake_read triage-family 7200); RC=$?
LAST1=$(jq -r '.ledgers[-1].updated_at' "$T/pages/1")
ENC=$(jq -nr --arg b "$LAST1" '$b|@uri')
ENCK=$(jq -r '.ledgers[-1].key|@uri' "$T/pages/1")
GET2=$(grep '^GET ' "$T/req.log" | sed -n 2p)
[ "$RC" -eq 0 ] && [ "$(grep -c . <<<"$OUT")" -eq 1003 ] \
  && grep -q "^k0${TAB}" <<< "$OUT" && grep -q "^k1002${TAB}" <<< "$OUT" \
  && [ "$(reqs)" -eq 2 ] \
  && ok || bad "two-page walk rc=$RC rows=$(printf '%s\n' "$OUT" | grep -c .) reqs=$(reqs)"
[ "$GET2" = "GET /api/ledger?kind=brake%3Atriage-family&limit=1000&before=$ENC&before_key=$ENCK " ] \
  && ok || bad "second request was '$GET2', wanted before=$ENC&before_key=$ENCK"

# --- 6. the 5-page cap -------------------------------------------------------
reset
for p in 1 2 3 4 5 6; do page "$T/pages/$p" 1000 $(( (p-1)*1000 )); done
OUT=$(run brake_read triage-family 100000); RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" -eq 5 ] && [ "$(printf '%s\n' "$OUT" | tail -1)" = "#truncated" ] \
  && [ "$(grep -c "$TAB" <<<"$OUT")" -eq 5000 ] \
  && ok || bad "cap: rc=$RC reqs=$(reqs) last='$(printf '%s\n' "$OUT" | tail -1)'"
# a 5th full page whose oldest row is out of window is complete, not truncated
reset
for p in 1 2 3 4 5; do page "$T/pages/$p" 1000 $(( (p-1)*1000 )); done
OUT=$(run brake_read triage-family 4500); RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" -eq 5 ] && ! grep -q '^#truncated' <<< "$OUT" \
  && [ "$(grep -c "$TAB" <<<"$OUT")" -eq 4501 ] \
  && ok || bad "out-of-window 5th page: rc=$RC reqs=$(reqs) rows=$(printf '%s\n' "$OUT" | grep -c "$TAB") last='$(printf '%s\n' "$OUT" | tail -1)'"
# a full page whose oldest row is out of window stops the walk early
reset
page "$T/pages/1" 1000 3000
OUT=$(run brake_read triage-family 3500); RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" -eq 1 ] && [ "$(grep -c "$TAB" <<<"$OUT")" -eq 501 ] \
  && ok || bad "old full page: rc=$RC reqs=$(reqs)"

# --- 7. only _jobs_req is reached --------------------------------------------
# Every case above ran with fake ssh/curl first on PATH; none may have fired.
reset
run brake_mark triage-family fam-a "$NOW" >/dev/null
run brake_read triage-family 3600 >/dev/null
run brake_clear triage-family fam-a >/dev/null
[ ! -s "$T/sink.ssh" ] && [ ! -s "$T/sink.curl" ] && ! grep -q '/api/boxes\|checkin\|check-in' "$T/req.log" \
  && [ "$(reqs)" -eq 3 ] \
  && ok || bad "something besides _jobs_req was called: $(cat "$T"/sink.* 2>/dev/null) / $(cat "$T/req.log")"

# --- 8. invalid input makes no request ---------------------------------------
for args in "triage-family k 12x" "triage-family k $NOW [1]" "triage-family k $NOW notjson" \
            "triage-family '' $NOW" "this-name-is-far-too-long-for-a-kind k $NOW" "Bad_Name k $NOW"; do
  reset
  eval "run brake_mark $args" >/dev/null; RC=$?
  [ "$RC" -eq 1 ] && [ "$(reqs)" -eq 0 ] && ok || bad "brake_mark $args rc=$RC reqs=$(reqs)"
done
for args in "triage-family 1h" "triage-family ''" "this-name-is-far-too-long-for-a-kind 60"; do
  reset
  OUT=$(eval "run brake_read $args"); RC=$?
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] && [ "$(reqs)" -eq 0 ] && ok || bad "brake_read $args rc=$RC reqs=$(reqs)"
done
reset
run brake_clear "" k; RC=$?
[ "$RC" -eq 1 ] && [ "$(reqs)" -eq 0 ] && ok || bad "brake_clear with no name rc=$RC reqs=$(reqs)"
# 26 chars is the longest name the worker's 32-char kind keeps whole
reset
run brake_mark abcdefghijklmnopqrstuvwxyz k "$NOW"; RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" -eq 1 ] && ok || bad "26-char name refused: rc=$RC"
reset
run brake_mark abcdefghijklmnopqrstuvwxyz0 k "$NOW"; RC=$?
[ "$RC" -eq 1 ] && [ "$(reqs)" -eq 0 ] && ok || bad "27-char name accepted: rc=$RC"

# --- 9. brake_db_on is alerts_db_on ------------------------------------------
dbon() {
  ( export HARNESS="$T/h" ALERTS_CONF="$T/h/flags/alerts.conf"
    # shellcheck source=/dev/null
    [ "${1:-}" = with-gate ] && . "$T/h/bin/lib/alert-state.sh" 2>/dev/null
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/brake-ledger.sh" || exit 99
    brake_db_on; echo $? )
}
touch "$T/h/flags/alerts-db"
[ "$(dbon)" = 1 ] && ok || bad "brake_db_on without alerts_db_on loaded gave $(dbon), wanted 1"
rm -f "$T/h/flags/alerts-db"
[ "$(dbon with-gate)" = 1 ] && ok || bad "brake_db_on with no flag gave $(dbon with-gate), wanted 1"
touch "$T/h/flags/alerts-db"
[ "$(dbon with-gate)" = 0 ] && ok || bad "brake_db_on with the flag gave $(dbon with-gate), wanted 0"
rm -f "$T/h/flags/alerts-db"

echo "brake-ledger.bh-2343: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
