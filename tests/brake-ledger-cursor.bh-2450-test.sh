#!/bin/bash
# tests/brake-ledger-cursor.bh-2450-test.sh — BH-2450: the ledger list pages on
# a compound (updated_at, key) cursor, and the #2343 lib passes the key back.
#
# Sources the checkout's real bin/jobs-client.sh (and its bin/lib/jobs modules)
# and the real bin/lib/brake-ledger.sh, and replaces ONLY _jobs_req with a stub
# that logs `METHOD PATH` and answers scripted pages, so the request lines below
# are the ones production sends.
#
#   A  ledger_page k 1000 T K sends &before=<enc T>&before_key=<enc K>
#   B  ledger_page k 1000 T sends no before_key (byte-identical to before)
#   C  brake_read over two pages whose page 1 ends on the key "a b<TAB>c":
#      the 2nd GET carries the @uri of the RAW key, not the @tsv-escaped one
#   D  a full page whose last row has no key is rc 1 with no output
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/brake-ledger-cursor.bh-2450-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/pages"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/h/bin/lib/alert-state.sh"

NOW=1790000000
export BRAKE_NOW=$NOW

run() {
  ( export HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=testbox
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/brake-ledger.sh" || exit 99
    _jobs_req() {
      printf '%s %s\n' "$1" "$2" >> "$T/req.log"
      local n; n=$(grep -c '^GET ' "$T/req.log")
      if [ -f "$T/pages/$n" ]; then cat "$T/pages/$n"; else printf '{"ledgers":[]}'; fi
      return 0
    }
    "$@" )
}
reset() { rm -f "$T/req.log" "$T"/pages/*; }
enc() { jq -nr --arg v "$1" '$v|@uri'; }
TAB=$(printf '\t')

# --- A. ledger_page with a 4th arg sends before_key --------------------------
reset
run ledger_page brake:triage-family 1000 2026-09-25T12:00:00Z 'fam a/b' >/dev/null; RC=$?
GET=$(sed -n 1p "$T/req.log")
[ "$RC" -eq 0 ] && [ "$GET" = "GET /api/ledger?kind=brake%3Atriage-family&limit=1000&before=$(enc 2026-09-25T12:00:00Z)&before_key=$(enc 'fam a/b')" ] \
  && ok || bad "A: 4-arg ledger_page rc=$RC sent '$GET'"

# --- B. ledger_page with 3 args is unchanged ---------------------------------
reset
run ledger_page brake:triage-family 1000 2026-09-25T12:00:00Z >/dev/null; RC=$?
GET=$(sed -n 1p "$T/req.log")
[ "$RC" -eq 0 ] && [ "$GET" = "GET /api/ledger?kind=brake%3Atriage-family&limit=1000&before=2026-09-25T12%3A00%3A00Z" ] \
  && ok || bad "B: 3-arg ledger_page rc=$RC sent '$GET'"
reset
run ledger_page brake:triage-family 1000 >/dev/null
GET=$(sed -n 1p "$T/req.log")
[ "$GET" = "GET /api/ledger?kind=brake%3Atriage-family&limit=1000" ] \
  && ok || bad "B: 2-arg ledger_page sent '$GET'"

# --- C. brake_read passes the raw last key back ------------------------------
# Page 1: 1000 set rows all on one second (a same-second burst), the last one
# keyed "a b<TAB>c". Page 2: 2 older rows. Every row is in the window.
reset
LASTKEY="a b${TAB}c"
jq -nc --argjson now "$NOW" --arg lk "$LASTKEY" \
  '{ledgers: [range(1000) as $i
     | {kind:"brake:triage-family", key:(if $i == 999 then $lk else "k\(9999 - $i)" end),
        status:"set", detail:({at:$now}|tojson), updated_at:($now|todate)}], as_of:"x"}' > "$T/pages/1"
jq -nc --argjson now "$NOW" \
  '{ledgers: [range(2) as $i
     | {kind:"brake:triage-family", key:"old\($i)", status:"set",
        detail:({at:($now-1)}|tojson), updated_at:(($now-1)|todate)}], as_of:"x"}' > "$T/pages/2"
OUT=$(run brake_read triage-family 3600); RC=$?
GET2=$(grep '^GET ' "$T/req.log" | sed -n 2p)
WANT="GET /api/ledger?kind=brake%3Atriage-family&limit=1000&before=$(enc "$(jq -nr --argjson n "$NOW" '$n|todate')")&before_key=$(enc "$LASTKEY")"
[ "$RC" -eq 0 ] && [ "$GET2" = "$WANT" ] \
  && ok || bad "C: second request was '$GET2', wanted '$WANT' (rc=$RC)"
[ "$(grep -c "$TAB" <<<"$OUT")" -eq 1002 ] && grep -q "^old1${TAB}" <<< "$OUT" \
  && ok || bad "C: brake_read printed $(printf '%s\n' "$OUT" | grep -c "$TAB") rows, wanted 1002"

# --- D. a full page with no last key is an outage ----------------------------
reset
jq -nc --argjson now "$NOW" \
  '{ledgers: [range(1000) as $i
     | {kind:"brake:triage-family", status:"set", detail:({at:$now}|tojson), updated_at:($now|todate)}
       + (if $i == 999 then {} else {key:"k\($i)"} end)], as_of:"x"}' > "$T/pages/1"
OUT=$(run brake_read triage-family 3600); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && [ "$(grep -c '^GET ' "$T/req.log")" -eq 1 ] \
  && ok || bad "D: keyless full page gave rc=$RC, $(printf '%s' "$OUT" | grep -c .) lines, $(grep -c '^GET ' "$T/req.log") requests"

echo "brake-ledger-cursor.bh-2450: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
