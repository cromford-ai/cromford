#!/bin/bash
# tests/alerts-client.bh-1068-test.sh — the alerts DB client contract, driven for real.
#
# The seven wrappers are thin: one jq body, one _jobs_req call, one jq parse.
# This suite drives the real bin/jobs-client.sh dispatch and the real
# bin/lib/alert-state.sh gate against a stubbed curl, then reads the recorded
# requests and the stdout/rc the production entry point returns.
#
# Run from anywhere: tests/alerts-client.bh-1068-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/env" "$T/fakebin" "$T/h/bin" "$T/h/bin/lib" "$T/h/logs" "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The script under test is the checkout copy, exactly as harness-sync installs it.
# BH-1194 made the client a SHIM over bin/lib/jobs/*.sh, and the modules resolve
# off BASH_SOURCE — so they are copied next to BOTH entry points this fixture
# offers (the copy under $T/bin, and the $T/h/bin symlink alert-state.sh sources
# through). A copy without them refuses to load rather than half-load a client.
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" "$T/h/bin/lib/jobs"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/h/bin/lib/alert-state.sh"
ln -sf "$T/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
echo 'HARNESS_SECRET=test-secret' > "$T/env/global.env"

# A fake curl that records METHOD URL BODY and answers body\n<status>.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H)
      # Do not let the bearer token leak into the request log we assert on.
      case "$2" in authorization:*) ;; *) echo "HEADER $2" >> "$REQ_SINK.headers" ;; esac
      shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)    exit 7 ;;
  garbage) printf 'not json at all\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "POST "*/api/alerts/note)     printf '{"decision":"fire","count":1,"as_of":"2026-09-19T21:00:00Z"}\n200\n' ;;
  "PATCH "*/api/alerts/state)   case "$BODY" in *\"id\":\"missing\"*) printf '{"error":"not found"}\n404\n' ;; *) printf '{"alert":{"id":"a1","state":"triaged"}}\n200\n' ;; esac ;;
  "POST "*/api/alerts/resolve) printf '{"resolved":2}\n200\n' ;;
  "POST "*/api/alerts/claim)    printf '{"alerts":[{"id":"a1","family":"f1","box":"box1","project":"p1","state":"new","count":1,"first_seen":"t1","last_seen":"t2","claimed_by":"lane@box","notified_at":"","severity":"critical","line":"fire in lane"},{"id":"a2","family":"f2","box":"box1","project":"p1","state":"new","count":2,"first_seen":"t1","last_seen":"t2","claimed_by":"","notified_at":"","severity":"warn","line":"line-with-tabs"}]}\n200\n' ;;
  "POST "*/api/alerts/flush)   printf '{"alerts":[]}\n200\n' ;;
  # The families arm comes FIRST: */api/alerts* matches the families URL too, so
  # the other order leaves this stub unreachable and alert_families untested.
  "GET "*/api/alerts/families*) printf '{"families":[{"family":"f1","last_claimed_at":"t1","n":3}]}\n200\n' ;;
  "GET "*/api/alerts*)         printf '{"alerts":[{"id":"a1","family":"f1","box":"box1","project":"p1","state":"new","count":1,"first_seen":"t1","last_seen":"t2","claimed_by":"","notified_at":"","severity":"critical","line":"one"},{"id":"a2","family":"f2","box":"box1","project":"p1","state":"new","count":1,"first_seen":"t1","last_seen":"t2","claimed_by":"","notified_at":"","severity":"warn","line":"two-with-tabs"}],"truncated":true,"as_of":"2026-09-19T21:00:00Z"}\n200\n' ;;
  "GET "*/api/settings/*)      printf '{"error":"not found"}\n404\n' ;;
  *)                            printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

fn() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" \
           ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    "$@" )
}

cli() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" \
           ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" 2>/dev/null )
}

reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log"; else echo 0; fi; }
body_of() { grep -m1 "$1" "$T/req.log" 2>/dev/null | sed 's/^[^ ]* [^ ]* //'; }

# --- 1. alert-note sends the right body and prints fire 1 --------------------
rm -f "$T/req.log"
OUT=$(fn alert_note my-id 0123456789ab my-box my-project critical "the line"); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "fire 1" ] && ok || bad "alert_note rc=$RC out='$OUT', wanted 0 'fire 1'"
BODY=$(body_of 'POST .*api/alerts/note')
if [ "$(printf '%s' "$BODY" | jq -r '.id')" = "my-id" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.family')" = "0123456789ab" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.box')" = "my-box" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.project')" = "my-project" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.severity')" = "critical" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.line')" = "the line" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "new" ]; then ok
else bad "alert-note body fields wrong: $BODY"; fi

# --- 2. alert_state_set sends a PATCH and prints changed ---------------------
rm -f "$T/req.log"
OUT=$(fn alert_state_set my-id triaged lane@box); RC=$?
# 1 = the worker's row came back in the state we asked for (the issue's <changed>).
[ "$RC" -eq 0 ] && [ "$OUT" = "1" ] && ok || bad "alert_state_set rc=$RC out='$OUT', wanted 0 '1'"
BODY=$(body_of 'PATCH .*api/alerts/state')
[ "$(printf '%s' "$BODY" | jq -r '.id')" = "my-id" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "triaged" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.actor')" = "lane@box" ] \
  && ok || bad "alert-state body wrong: $BODY"

# --- 3. alert_resolve is variadic and prints resolved ------------------------
rm -f "$T/req.log"
OUT=$(fn alert_resolve a1 a2); RC=$?
# The stub moved 2 rows: the caller sees 2, not the literal the client used to print.
[ "$RC" -eq 0 ] && [ "$OUT" = "2" ] && ok || bad "alert_resolve rc=$RC out='$OUT', wanted 0 '2'"
BODY=$(body_of 'POST .*api/alerts/resolve')
[ "$(printf '%s' "$BODY" | jq -r '.ids | length')" -eq 2 ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.ids[0]')" = "a1" ] \
  && ok || bad "alert-resolve body wrong: $BODY"

# --- 4. alerts (list) renders two TSV rows, line last, and #truncated --------
rm -f "$T/req.log"
OUT=$(cli alerts --state new --limit 10); RC=$?
[ "$RC" -eq 0 ] && ok || bad "alerts cli rc=$RC"
NLINES=$(printf '%s\n' "$OUT" | grep -c '^[^#]') || true
[ "$NLINES" -eq 2 ] && ok || bad "alerts printed $NLINES data rows, wanted 2"
COLS=$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')
[ "$COLS" -eq 13 ] && ok || bad "alerts first row has $COLS columns, wanted 13 (12 before line)"
LASTCOL=$(head -1 <<<"$OUT" | awk -F'\t' '{print $NF}')
[ "$LASTCOL" = "one" ] && ok || bad "alerts line column is '$LASTCOL', wanted 'one'"
grep -qx '#truncated' <<<"$OUT" && ok || bad "missing #truncated line; output was:\n$OUT"

# --- 5. 404 maps to rc 2 and empty stdout; outage maps to rc 1 ---------------
rm -f "$T/req.log"
OUT=$(cli alert-state missing triaged); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "404 gave rc=$RC out='$OUT', wanted 2 and empty"

rm -f "$T/req.log"
OUT=$(EXTRA_ENV="CURL_MODE=down" cli alert-state missing triaged); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "outage gave rc=$RC out='$OUT', wanted 1 and empty"

# --- 5b. alert_claim's positionals never ride onto the wire as ids -----------
# min_age_s and limit are positional 3 and 4. If the wrapper forwards them into
# the id list, the worker reads `ids` as a FILTER and the claim matches nothing
# — an empty answer with rc 0, forever, which reads as "queue is empty".
rm -f "$T/req.log"
fn alert_claim alert-triage quarantined 0 200 >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r '.lane')" = "alert-triage" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.min_age_s')" = "0" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.limit')" = "200" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.ids // "none"')" = "none" ] \
  && ok || bad "alert_claim with no ids must send no ids key: $BODY"

rm -f "$T/req.log"
fn alert_claim medic new 0 2 a1 a2 >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r '.ids | join(",")')" = "a1,a2" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.limit')" = "2" ] \
  && ok || bad "alert_claim ids must be exactly the trailing arguments: $BODY"

# The empty-string form callers used to dodge the bug keeps working: no
# min_age_s, no limit, ids exactly as given.
rm -f "$T/req.log"
fn alert_claim medic new "" "" a1 >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r '.ids | join(",")')" = "a1" ] \
  && [ "$(printf '%s' "$BODY" | jq -r 'has("min_age_s")')" = "false" ] \
  && [ "$(printf '%s' "$BODY" | jq -r 'has("limit")')" = "false" ] \
  && ok || bad "alert_claim with empty min/limit must send ids only: $BODY"

# --- 6. alerts_db_on gate ----------------------------------------------------
gate() {
  ( export HARNESS="$T/h" ALERTS_CONF="$T/h/flags/alerts.conf"
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/alert-state.sh" 2>/dev/null
    alerts_db_on; echo $? )
}
rm -f "$T/h/flags/alerts-db" "$T/h/flags/alerts.conf"
[ "$(gate)" = "1" ] && ok || bad "alerts_db_on with no flag returned $(gate), wanted 1"

touch "$T/h/flags/alerts-db"
[ "$(gate)" = "0" ] && ok || bad "alerts_db_on with flag present returned $(gate), wanted 0"

printf 'set ALERTS_DB_ENABLED 0\n' > "$T/h/flags/alerts.conf"
[ "$(gate)" = "1" ] && ok || bad "alerts_db_on with ALERTS_DB_ENABLED=0 returned $(gate), wanted 1"

# The kill switch an operator actually reaches for is the TEMPLATE's line,
# uncommented verbatim. alert_cfg takes everything after the name as the value,
# so a trailing comment on that line makes the switch read as "0 # kill..." and
# fail OPEN. Seeding the conf from the template is what keeps the two in step.
TPL_LINE=$(grep -E '^# *set ALERTS_DB_ENABLED ' "$DIR/env-templates/alerts.conf.example" | head -1 | sed 's/^# *//')
[ -n "$TPL_LINE" ] && ok || bad "env-templates/alerts.conf.example carries no commented 'set ALERTS_DB_ENABLED' line"
printf '%s\n' "$TPL_LINE" > "$T/h/flags/alerts.conf"
[ "$(gate)" = "1" ] && ok || bad "kill switch uncommented from the template returned $(gate), wanted 1 (conf line: '$TPL_LINE')"
rm -f "$T/h/flags/alerts-db" "$T/h/flags/alerts.conf"

# --- 6b. the gate does not leak jobs-client.sh's `set -uo pipefail` ----------
# jobs-client.sh sets -uo pipefail at its top level and alerts_db_on sources it;
# beat.sh runs -u WITHOUT pipefail, so a leak changes pipeline rc for the rest
# of that run. The gate must hand the caller back the options it was called with.
touch "$T/h/flags/alerts-db"
PF=$( export HARNESS="$T/h" ALERTS_CONF="$T/h/flags/alerts.conf"
      set +o pipefail
      # shellcheck source=/dev/null
      . "$T/h/bin/lib/alert-state.sh" 2>/dev/null
      alerts_db_on
      shopt -po pipefail )
[ "$PF" = "set +o pipefail" ] && ok || bad "alerts_db_on left the caller with '$PF', wanted 'set +o pipefail'"
rm -f "$T/h/flags/alerts-db"

# --- 7. the bearer token never leaks into the recorded request ---------------
LEAKED=0
[ -f "$T/req.log" ] && grep -q 'test-secret' "$T/req.log" 2>/dev/null && LEAKED=1
[ "$LEAKED" -eq 0 ] && ok || bad "bearer secret leaked into req.log"

# --- 8. regression: before this slice alert-note is an unknown verb ----------
# Simulate main by running the checkout copy with the new verbs absent: we
# cannot actually travel back in time, so this asserts the failure mode the
# fleet relies on — an unknown verb exits 2 with usage.
RC=0; bash "$DIR/bin/jobs-client.sh" alert-not-a-verb x x x x x >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && ok || bad "unknown verb alert-not-a-verb gave rc=$RC, wanted 2"

# --- 9. alert_claim: positional options are options, never ids ---------------
# The documented call is `alert_claim <lane> <state> [min_age_s] [limit] [id...]`.
# min_age_s/limit must be CONSUMED: folding them into ids scopes the claim to
# ids like "60"/"10", which the worker accepts, finds nothing for, and answers
# 200 {alerts:[]} — a lane that claims nothing, forever, with no error anywhere.
rm -f "$T/req.log"
OUT=$(EXTRA_ENV="JOBS_BOX=test-box" fn alert_claim medic new 60 10); RC=$?
BODY=$(body_of 'POST .*api/alerts/claim')
if [ "$RC" -eq 0 ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.lane')" = "medic" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "new" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.min_age_s')" = "60" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.limit')" = "10" ] \
   && [ "$(printf '%s' "$BODY" | jq -r 'has("ids")')" = "false" ]; then ok
else bad "alert_claim with options sent rc=$RC body=$BODY (wanted no .ids)"; fi
NLINES=$(printf '%s\n' "$OUT" | grep -c '^[^#]') || true
[ "$NLINES" -eq 2 ] && ok || bad "alert_claim printed $NLINES rows, wanted 2"

# --- 9b. alert_claim: the claimant is <lane>@<box>, never a bare lane --------
# claimed_by is documented as `<lane>@<box>` and the 6h family brake matches on
# `substr(claimed_by,1,n)='<lane>@'`, so a claim filed under the bare lane is
# invisible to `alert-families <lane>` forever: the brake never engages, the
# console's CLAIMED BY shows a lane with no box, and nothing errors anywhere.
# The client carries $JOBS_BOX; the worker composes.
rm -f "$T/req.log"
EXTRA_ENV="JOBS_BOX=test-box" fn alert_claim medic new >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r '.lane')" = "medic" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.box')" = "test-box" ] \
  && ok || bad "alert_claim did not carry the box: $BODY"

# A lane that already carries its box is sent as-is. The worker composes only
# when `box` is present, so sending both would file `medic@a@test-box` — a
# claimant no families query would ever match either.
rm -f "$T/req.log"
EXTRA_ENV="JOBS_BOX=test-box" fn alert_claim medic@a new >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r '.lane')" = "medic@a" ] \
  && [ "$(printf '%s' "$BODY" | jq -r 'has("box")')" = "false" ] \
  && ok || bad "alert_claim doubled the box on an already-qualified lane: $BODY"

# --- 10. alert_claim: ids ride AFTER both options, and only the ids ----------
rm -f "$T/req.log"
fn alert_claim medic new 60 10 a1 a2 >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
if [ "$(printf '%s' "$BODY" | jq -r '.ids | length')" = "2" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.ids[0]')" = "a1" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.ids[1]')" = "a2" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.limit')" = "10" ]; then ok
else bad "alert_claim ids body wrong: $BODY"; fi

rm -f "$T/req.log"
fn alert_claim medic new >/dev/null
BODY=$(body_of 'POST .*api/alerts/claim')
[ "$(printf '%s' "$BODY" | jq -r 'has("ids"), has("min_age_s"), has("limit")' | sort -u)" = "false" ] \
  && ok || bad "bare alert_claim sent more than lane/state: $BODY"

# --- 11. alert_flush_claim posts the box and renders an empty page ------------
rm -f "$T/req.log"
OUT=$(fn alert_flush_claim box1); RC=$?
BODY=$(body_of 'POST .*api/alerts/flush')
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(printf '%s' "$BODY" | jq -r '.box')" = "box1" ] \
  && ok || bad "alert_flush_claim rc=$RC out='$OUT' body=$BODY"

# --- 12. alert_families reads the families stub ------------------------------
rm -f "$T/req.log"
OUT=$(cli alert-families medic 900); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'f1\tt1\t3')" ] \
  && ok || bad "alert-families rc=$RC out='$OUT', wanted 'f1<TAB>t1<TAB>3'"

# --- 13. a 200 that is not JSON is an error, never "no alerts" ---------------
# A Cloudflare error page or a truncated body must not read as an empty table to
# a flush lane deciding there is nothing to escalate.
rm -f "$T/req.log"
OUT=$(EXTRA_ENV="CURL_MODE=garbage" cli alerts --state new); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "non-JSON 200 gave rc=$RC out='$OUT', wanted 1 and empty"

# Same for the wrappers that parse a scalar out of the body: a blank line and
# rc 0 is the same lie in a different shape.
for V in "alert-note i f b p critical line" "alert-resolve a1" "alert-state a1 triaged" "alert-claim medic new" "alert-families medic 900"; do
  # shellcheck disable=SC2086
  OUT=$(EXTRA_ENV="CURL_MODE=garbage" cli $V); RC=$?
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "non-JSON 200 on '$V' gave rc=$RC out='$OUT', wanted 1 and empty"
done

echo "alerts-client-bh-1068: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
