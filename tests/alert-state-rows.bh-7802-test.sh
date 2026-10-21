#!/bin/bash
# tests/alert-state-rows.bh-7802-test.sh — BH-7802 (BH-4157.2): with
# flags/alerts-db on, the alert-state READERS decide from the `alerts` row, and
# state/alerts/<id>.json is only the fallback when the worker does not answer.
#
# The readers under test, each driven through its production entry point:
#   alert_state_resolve  count and severity of the closed condition (R*, L1)
#   alert_state_age      how long it was open (A*, L1)
#   alert_state_open     open or closed, for tz-check and disk-guard (O*, Z*, D*)
# and the two jobs-client calls they read through, alert_row and
# alert_resolve_rows (C*). The worker side is worker/jobs/test/
# alerts-rows.bh-7802.test.js; both suites read the one resolve body in
# tests/fixtures/bh-7802/resolve-rows.json.
#
# curl is a fake on PATH that answers from files under $T/fix and records every
# request, so "0 requests" is a real assertion: flag off must stay off the wire.
#
# Run from anywhere: tests/alert-state-rows.bh-7802-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Every fixture age is derived from NOW. reset() reads the clock again before
# each case, so a slow box cannot stretch one case's window (ages are +-5 s).
NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
HOST=box-fixture   # what the fake `hostname` below prints; disk-guard ids carry it

# Two harness trees with the same libraries. $H runs the REAL lane-alert.sh
# (L1); $HZ has a recording lane-alert.sh stub for tz-check and disk-guard,
# where the assertion is which --resolve calls were made.
H="$T/h"; HZ="$T/hz"; FIX="$T/fix"
for root in "$H" "$HZ"; do
  mkdir -p "$root/bin/lib" "$root/logs" "$root/state/alerts" "$root/flags" "$root/env"
done
mkdir -p "$FIX/rows" "$T/fakebin"
printf '#!/bin/sh\necho box-fixture\n' > "$T/fakebin/hostname"; chmod +x "$T/fakebin/hostname"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beat.log"\n' "$T" > "$H/bin/beat.sh"
cat > "$HZ/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$(cd "$(dirname "$0")/.." && pwd)/la.calls"
SH
chmod +x "$H/bin/beat.sh" "$HZ/bin/lane-alert.sh"
printf 'boxz\n' > "$HZ/state/box-id"
for root in "$H" "$HZ"; do
  for s in bin/lane-alert.sh bin/jobs-client.sh bin/disk-guard.sh bin/lib/tz-check.sh bin/lib/alert-state.sh; do
    scratch_install_closure "$s" "$root" >/dev/null || { echo "FAIL: cannot install $s"; exit 1; }
  done
done
: > "$T/alerts.conf"

# --- the fake worker ---------------------------------------------------------
# GET /api/alerts?id=<id>: $FIX/rows/<id>.json, else an empty list (the worker
# filters by exact id, so a row for tz_box2 is never the answer for tz_box).
# POST /api/alerts/resolve: $FIX/resolve.json. CURL_MODE=down is a transport
# failure, CURL_MODE=garbage a 200 that is not JSON, CURL_MODE=list a worker
# that ignores ?id= and answers its newest row ($FIX/list.json).
{ echo '#!/bin/bash'; echo "FIX=$FIX"; cat <<'CURLEOF'
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$FIX/calls.log"
case "${CURL_MODE:-ok}" in
  down)    exit 7 ;;
  garbage) printf '<html>bad gateway</html>\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "GET "*/api/alerts\?id=*)
    if [ "${CURL_MODE:-ok}" = list ]; then printf '%s\n200\n' "$(cat "$FIX/list.json")"; exit 0; fi
    id="${URL#*\?id=}"; id="${id%%&*}"
    if [ -f "$FIX/rows/$id.json" ]; then printf '%s\n200\n' "$(cat "$FIX/rows/$id.json")"
    else printf '{"alerts":[],"truncated":false,"as_of":"2026-10-21T00:00:00Z"}\n200\n'; fi ;;
  "POST "*/api/alerts/resolve) printf '%s\n200\n' "$(cat "$FIX/resolve.json")" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURLEOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"

# row <id> <state> <count> <severity> <first_seen-iso> [truncated] — the row
# the worker answers for <id>, in the GET /api/alerts body shape.
row() {
  jq -nc --arg id "$1" --arg s "$2" --argjson c "$3" --arg sev "$4" --arg fs "$5" --argjson tr "${6:-false}" \
    '{alerts:[{id:$id,family:null,box:"boxz",project:"",state:$s,count:$c,first_seen:$fs,
      last_seen:$fs,claimed_by:null,claimed_at:null,notified_at:null,severity:$sev,line:"x"}],
      truncated:$tr,as_of:"2026-10-21T00:00:00Z"}' > "$FIX/rows/$1.json"
}
# sfile <root> <id> <count> <severity> <first_seen-epoch> <resolved_at|null>
sfile() {
  jq -nc --argjson c "$3" --arg s "$4" --argjson f "$5" --argjson r "$6" \
    '{first_seen:$f,last_seen:$f,last_notified:$f,count:$c,severity:$s,resolved_at:$r,line:"x"}' \
    > "$1/state/alerts/$2.json"
}
reset() {
  NOW=$(date -u +%s)
  local p
  for p in "$FIX/rows" "$FIX/calls.log" "$FIX/resolve.json" "$FIX/list.json" \
           "$H/state/alerts" "$HZ/state/alerts" "$H/logs/alerts-state.log" "$HZ/la.calls" \
           "$H/logs/ALERTS.log" "$T/beat.log"; do
    scratch_rm "$p" || exit 1
  done
  mkdir -p "$FIX/rows" "$H/state/alerts" "$HZ/state/alerts"
  touch "$H/flags/alerts-db" "$HZ/flags/alerts-db"
}
calls() { if [ -f "$FIX/calls.log" ]; then wc -l < "$FIX/calls.log"; else echo 0; fi; }

# fn <root> <command...> — run it in a shell that sourced the root's
# alert-state.sh and jobs-client.sh, the way lane-alert.sh and the gate do.
fn() {
  local root="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$root" HARNESS_SECRET=test-secret-fixture \
           JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
           ALERTS_CONF="$T/alerts.conf" CURL_MODE="${CURL_MODE:-ok}" LANE_GATE_DISABLE=1
    unset ALERT_STATE_DIR ALERT_STATE_LOG
    . "$root/bin/lib/alert-state.sh"
    . "$root/bin/jobs-client.sh"
    "$@" ) 2>/dev/null
}

# ══ C. the jobs-client calls ═════════════════════════════════════════════════
reset
row c1 new 3 warn "$(iso 600)"
OUT=$(fn "$H" alert_row c1); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | cut -f1)" = c1 ] && [ "$(printf '%s' "$OUT" | cut -f5)" = new ] \
  && [ "$(printf '%s' "$OUT" | cut -f6)" = 3 ] && [ "$(printf '%s' "$OUT" | cut -f7)" = "$(iso 600)" ] \
  && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "C1 alert_row prints the one row (rc=$RC out='$OUT')"
grep -q '^GET https://jobs.invalid/api/alerts?id=c1&limit=1$' "$FIX/calls.log" && ok \
  || bad "C1 alert_row asks for ?id=c1&limit=1 ($(cat "$FIX/calls.log"))"
OUT=$(fn "$H" alert_row c2); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C1 a 0-row answer is rc 0 and nothing (rc=$RC out='$OUT')"
OUT=$(CURL_MODE=garbage fn "$H" alert_row c1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C3 a 200 that is not JSON is rc 1, never 'no row' (rc=$RC out='$OUT')"
row other new 1 warn "$(iso 60)"; cp "$FIX/rows/other.json" "$FIX/list.json"
OUT=$(CURL_MODE=list fn "$H" alert_row c1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C3 a worker that ignores ?id= (another id's row) is rc 1 (rc=$RC out='$OUT')"
rm -f "$FIX/calls.log"
OUT=$(fn "$H" alert_row 'a/b'); RC=$?
[ "$RC" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "C4 an id with / is rc 1 and no request (rc=$RC calls=$(calls))"

cp "$DIR/tests/fixtures/bh-7802/resolve-rows.json" "$FIX/resolve.json"
OUT=$(fn "$H" alert_resolve_rows r1 r2); RC=$?
WANT=$(printf 'r1\t4\twarn\t2026-09-19T11:30:00Z\nr2\t1\tcritical\t2026-09-19T11:50:00Z\nresolved 2')
[ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && ok || bad "C2 alert_resolve_rows parses the route body (rc=$RC out='$OUT')"
printf '{"resolved":1}' > "$FIX/resolve.json"
OUT=$(fn "$H" alert_resolve_rows r1); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$(printf '#norows\nresolved 1')" ] && ok || bad "C2 an older worker's body (no rows key) prints #norows (rc=$RC out='$OUT')"
printf '{"rows":[]}' > "$FIX/resolve.json"
OUT=$(fn "$H" alert_resolve_rows r1); RC=$?
[ "$RC" = 1 ] && ok || bad "C2 a body with no resolved count is rc 1 (rc=$RC out='$OUT')"
OUT=$(CURL_MODE=garbage fn "$H" alert_resolve_rows r1); RC=$?
[ "$RC" = 1 ] && ok || bad "C3 alert_resolve_rows: a 200 that is not JSON is rc 1 (rc=$RC out='$OUT')"

# ══ R. alert_state_resolve: count and severity from the row ═══════════════════
resolve_body() { # resolve_body <id> <count> <severity> — one moved row
  jq -nc --arg id "$1" --argjson c "$2" --arg s "$3" --arg fs "$(iso 1800)" \
    '{resolved:1,rows:[{id:$id,count:$c,severity:$s,first_seen:$fs}],as_of:"x"}' > "$FIX/resolve.json"
}
reset; resolve_body x1 4 warn
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 4 warn" ] && ok || bad "R1 no file, row warn n=4 -> 'resolve 4 warn' (got '$OUT')"

reset; resolve_body x1 4 warn; sfile "$H" x1 9 critical "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 4 warn" ] && ok || bad "R2 the row beats the file (critical n=9) -> 'resolve 4 warn' (got '$OUT')"
R=$(jq -r '.resolved_at' "$H/state/alerts/x1.json")
[ "${R:-0}" != null ] && [ "${R:-0}" -gt 0 ] && ok || bad "R2 the file is still stamped resolved_at (got '$R')"

reset; printf '{"resolved":0,"rows":[]}' > "$FIX/resolve.json"; sfile "$H" x1 2 critical "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "silent 0 info" ] && ok || bad "R3 the row was already closed (resolved 0) -> silent, open file or not (got '$OUT')"

reset; printf '{"resolved":1}' > "$FIX/resolve.json"; sfile "$H" x1 2 warn "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 2 warn" ] && ok || bad "R4 #norows (older worker) -> the file's count and severity (got '$OUT')"
reset; printf '{"resolved":1}' > "$FIX/resolve.json"
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 1 critical" ] && ok || bad "R4 #norows and no file -> today's default 'resolve 1 critical' (got '$OUT')"
reset; jq -nc '{resolved:1,rows:[{id:"x1",count:"lots",severity:"loud",first_seen:"x"}]}' > "$FIX/resolve.json"
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 1 critical" ] && ok || bad "R4 a row with an unreadable count and severity -> 1 critical (got '$OUT')"

reset; sfile "$H" x1 3 warn "$(( NOW - 600 ))" null
OUT=$(CURL_MODE=down fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 3 warn" ] && ok || bad "R5 outage -> the file decides (got '$OUT')"
[ "$(grep -c 'db-miss id=x1' "$H/logs/alerts-state.log" 2>/dev/null)" = 1 ] && ok \
  || bad "R5 outage -> exactly one db-miss line ($(cat "$H/logs/alerts-state.log" 2>/dev/null))"

reset; printf '{"resolved":"x"}' > "$FIX/resolve.json"; sfile "$H" x1 3 warn "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 3 warn" ] && ok || bad "R5 a non-integer resolved -> the file decides (got '$OUT')"

reset; rm -f "$H/flags/alerts-db"; resolve_body x1 4 warn; sfile "$H" x1 3 critical "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_resolve x1)
[ "$OUT" = "resolve 3 critical" ] && [ "$(calls)" = 0 ] && ok \
  || bad "R6 flag off -> the file answer and no request (got '$OUT', calls=$(calls))"

# ══ A. alert_state_age: first_seen from the row ══════════════════════════════
near() { [ -n "$1" ] && [ "$1" -ge $(( $2 - 5 )) ] && [ "$1" -le $(( $2 + 5 )) ]; }
reset; row y1 new 2 warn "$(iso 1800)"
OUT=$(fn "$H" alert_state_age y1)
near "$OUT" 1800 && ok || bad "A1 no file, row 30 min old -> ~1800 (got '$OUT')"
reset; row y1 new 2 warn "$(iso 1800)"; sfile "$H" y1 2 warn "$(( NOW - 60 ))" null
OUT=$(fn "$H" alert_state_age y1)
near "$OUT" 1800 && ok || bad "A2 row and file disagree -> the row (got '$OUT')"
reset; sfile "$H" y1 2 warn "$(( NOW - 600 ))" null
OUT=$(CURL_MODE=down fn "$H" alert_state_age y1)
near "$OUT" 600 && ok || bad "A3 outage -> the file's age (got '$OUT')"
reset; sfile "$H" y1 2 warn "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_age y1)
near "$OUT" 600 && ok || bad "A3 the worker has no row -> the file's age (got '$OUT')"
reset; rm -f "$H/flags/alerts-db"; row y1 new 2 warn "$(iso 1800)"; sfile "$H" y1 2 warn "$(( NOW - 600 ))" null
OUT=$(fn "$H" alert_state_age y1)
near "$OUT" 600 && [ "$(calls)" = 0 ] && ok || bad "A4 flag off -> the file's age, no request (got '$OUT', calls=$(calls))"

# ══ O. alert_state_open ══════════════════════════════════════════════════════
is_open() { fn "$H" alert_state_open "$@"; echo $?; }
for s in new quarantined parked triaged resolvedx; do
  reset; row o1 "$s" 1 warn "$(iso 60)"
  [ "$(is_open o1)" = 0 ] && ok || bad "O1-4 row state $s -> open (rc 0)"
done
reset; row o1 resolved 1 warn "$(iso 60)"; sfile "$H" o1 1 warn "$(( NOW - 60 ))" null
[ "$(is_open o1)" = 1 ] && ok || bad "O5 row resolved -> closed, whatever the file says"
reset; sfile "$H" o1 1 warn "$(( NOW - 60 ))" null; row o12 new 1 warn "$(iso 60)"
[ "$(is_open o1)" = 1 ] && ok || bad "O6 the worker has no row for o1 (o12 is another id) -> closed"
reset; sfile "$H" o1 1 warn "$(( NOW - 60 ))" null
[ "$(CURL_MODE=down is_open o1)" = 0 ] && ok || bad "O7 outage + file resolved_at null -> open"
reset; printf '{"count":1}' > "$H/state/alerts/o1.json"
[ "$(CURL_MODE=down is_open o1)" = 0 ] && ok || bad "O7 outage + file with no resolved_at -> open (falls toward calling)"
reset; sfile "$H" o1 1 warn "$(( NOW - 60 ))" 1760000000
[ "$(CURL_MODE=down is_open o1)" = 1 ] && ok || bad "O7 outage + file resolved_at set -> closed"
reset
[ "$(CURL_MODE=garbage is_open o1)" = 1 ] && ok || bad "O8 a non-JSON 200 and no file -> the file rule, closed"
reset; sfile "$H" o1 1 warn "$(( NOW - 60 ))" null
[ "$(CURL_MODE=garbage is_open o1)" = 0 ] && ok || bad "O8 a non-JSON 200 is an outage, not 'no row': open file -> open"
reset; sfile "$H" o1 1 warn "$(( NOW - 60 ))" null; row other new 1 warn "$(iso 60)"; cp "$FIX/rows/other.json" "$FIX/list.json"
[ "$(CURL_MODE=list is_open o1)" = 0 ] && ok || bad "O8 a worker that ignores ?id= -> the file rule, open"
rm -f "$H/state/alerts/o1.json"
[ "$(CURL_MODE=list is_open o1)" = 1 ] && ok || bad "O8 a worker that ignores ?id= and no file -> closed, another id's open row never counts"
reset; row o1 new 1 warn "$(iso 60)" true
[ "$(is_open o1)" = 0 ] && ok || bad "O8 a #truncated line next to the row -> the row still reads open"
reset; row o1 resolved 1 warn "$(iso 60)" true
[ "$(is_open o1)" = 1 ] && ok || bad "O8 a #truncated line next to a resolved row -> closed"
reset; rm -f "$H/flags/alerts-db"; row o1 new 1 warn "$(iso 60)"
[ "$(is_open o1)" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "O9 flag off, no file -> closed, no request"
reset; rm -f "$H/flags/alerts-db"; sfile "$H" o1 1 warn "$(( NOW - 60 ))" 1760000000
[ "$(is_open o1)" = 1 ] && ok || bad "O9 flag off, closed file -> closed"
[ "$(is_open o1 --file-exists)" = 0 ] && ok || bad "O9 flag off, closed file, --file-exists -> open (disk-guard's rule)"
reset; rm -f "$H/flags/alerts-db"
[ "$(is_open o1 --file-exists)" = 1 ] && ok || bad "O9 flag off, no file, --file-exists -> closed"
[ "$(is_open '')" = 1 ] && ok || bad "O9 an empty id -> closed"

# ══ Z. tz-check reads the row ════════════════════════════════════════════════
tz() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HZ" HARNESS_SECRET=test-secret-fixture \
           JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 ALERTS_CONF="$T/alerts.conf" \
           TZ_OVERRIDE=UTC TZ_CHECK=1 LANE_GATE_DISABLE=1
    unset ALERT_STATE_DIR ALERT_STATE_LOG
    . "$HZ/bin/lib/tz-check.sh"; tz_check "$HZ" ) >/dev/null 2>&1
}
la_calls() { if [ -f "$HZ/la.calls" ]; then grep -c -- "$1" "$HZ/la.calls"; else echo 0; fi; }
reset; row tz_boxz new 1 critical "$(iso 600)"
tz
[ "$(la_calls '--resolve --id tz:boxz')" = 1 ] && [ "$(wc -l < "$HZ/la.calls")" = 1 ] && ok \
  || bad "Z1 open row, no file -> one --resolve call ($(cat "$HZ/la.calls" 2>/dev/null))"
reset; row tz_boxz resolved 1 critical "$(iso 600)"; sfile "$HZ" tz_boxz 1 critical "$(( NOW - 600 ))" null
tz
[ ! -f "$HZ/la.calls" ] && ok || bad "Z2 resolved row (open file) -> no call ($(cat "$HZ/la.calls"))"
reset; row tz_boxz2 new 1 critical "$(iso 600)"
tz
[ ! -f "$HZ/la.calls" ] && ok || bad "Z2 a row for tz_boxz2 is not tz_boxz -> no call ($(cat "$HZ/la.calls"))"
reset; rm -f "$HZ/flags/alerts-db"; row tz_boxz new 1 critical "$(iso 600)"
tz
[ ! -f "$HZ/la.calls" ] && [ "$(calls)" = 0 ] && ok || bad "Z3 flag off, no file -> no call and no request"
sfile "$HZ" tz_boxz 1 critical "$(( NOW - 600 ))" null
tz
[ "$(la_calls '--resolve --id tz:boxz')" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "Z3 flag off, open file -> one call, no request"

# ══ D. disk-guard reads the row ══════════════════════════════════════════════
printf '#!/bin/bash\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/root 41152736 30000000 2097152 50%%%% /\\n"\n' > "$T/fakebin/df"
chmod +x "$T/fakebin/df"
dg() {
  ( env PATH="$T/fakebin:$PATH" HARNESS="$HZ" HOME="$T" HARNESS_SECRET=test-secret-fixture \
        JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 ALERTS_CONF="$T/alerts.conf" LANE_GATE_DISABLE=1 \
        bash "$HZ/bin/disk-guard.sh" ) >/dev/null 2>&1
}
reset; row "disk-high-$HOST" new 1 warn "$(iso 600)"
dg
[ "$(la_calls "--resolve --id disk-high-$HOST")" = 1 ] && [ "$(wc -l < "$HZ/la.calls")" = 1 ] && ok \
  || bad "D1 50% with an open disk-high row and no file -> one --resolve call ($(cat "$HZ/la.calls" 2>/dev/null))"
reset; row "disk-high-$HOST" resolved 1 warn "$(iso 600)"; sfile "$HZ" "disk-high-$HOST" 1 warn "$(( NOW - 600 ))" null
dg
[ ! -f "$HZ/la.calls" ] && ok || bad "D2 resolved row (file present) -> no call ($(cat "$HZ/la.calls"))"
reset; rm -f "$HZ/flags/alerts-db"; sfile "$HZ" "disk-high-$HOST" 1 warn "$(( NOW - 600 ))" 1760000000
dg
[ "$(la_calls "--resolve --id disk-high-$HOST")" = 1 ] && [ "$(calls)" = 0 ] && ok \
  || bad "D3 flag off, file present (closed) -> one call as today, no request ($(cat "$HZ/la.calls" 2>/dev/null))"

# ══ L. the RESOLVED line, through the real bin/lane-alert.sh ═════════════════
reset; resolve_body lx 4 warn; row lx new 4 warn "$(iso 1800)"
( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture \
         JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 ALERTS_CONF="$T/alerts.conf" LANE_GATE_DISABLE=1
  unset ALERT_STATE_DIR ALERT_STATE_LOG
  bash "$H/bin/lane-alert.sh" --resolve --id lx tz-check "it is fine now" ) >/dev/null 2>&1
grep -q 'RESOLVED: it is fine now (was firing n=4 for 30m)' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "L1 RESOLVED line carries the row's count and age ($(cat "$H/logs/ALERTS.log" 2>/dev/null))"
SEVS=$(jq -r 'select(.alertid=="lx") | .severity' "$T/beat.log" 2>/dev/null | sort -u)
[ "$SEVS" = warn ] && ok || bad "L1 the beat rides the row's severity warn (got '$SEVS'; $(cat "$T/beat.log" 2>/dev/null))"

echo "alert-state-rows.bh-7802: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
