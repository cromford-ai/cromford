#!/bin/bash
# tests/doorbell-cursor-lag.bh-6799-test.sh — BH-6799: the daily doorbell lane
# ("$DIR/bin/doorbell-coverage-check.sh") reads GET /api/wakes/cursor?all=1
# after its prune and writes ONE ALERTS line per stale box per UTC day.
#
# The worker answer is the shape worker/jobs/test/wakes-cursor-hygiene.bh-6799
# asserts on the real route: {max_id, lag_rows, lag_s, cursors:[{box, cursor,
# updated_at, lag, stale}], as_of}. What must NOT happen:
#   * a worker 500 or an outage is an ALERT (it is one LOG line, no alert);
#   * a second run the same day alerts the same box again;
#   * a box with stale:false is alerted;
#   * a --repo run (one project's onboarding check) reads the cursors at all.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/doorbell-cursor-lag.bh-6799-test.sh
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
: > "$HARNESS/env/global.env"
export CALLS="$T/calls" CURSOR_JSON="$T/cursor.json" CURSOR_DOWN="$T/cursor.down" CURSOR_500="$T/cursor.500"
export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<EOF
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
armed-proj    Test/armed      -  -  1  box-test 100.0.0.1
EOF

# gh: the one repo rings (the summary below), so its hooks are never read.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/wakes/cursor?all=1"*)
    echo "${!#}" >> "$CALLS/cursor"
    [ -f "$CURSOR_DOWN" ] && exit 7
    if [ -f "$CURSOR_500" ]; then printf '{"error":"boom"}\n500'; exit 0; fi
    printf '%s\n200' "$(cat "$CURSOR_JSON")"
    exit 0 ;;
  *"/api/wakes/prune"*)
    printf '{"deleted":0,"before":"2026-09-15T00:00:00Z","capped":false,"cursors_deleted":1}\n200'; exit 0 ;;
  *"/api/wakes/summary"*)
    printf '{"repos":[{"repo":"Test/armed","last_id":7,"last_at":"2026-10-15T07:00:00Z","kinds":"pr"}]}\n200'; exit 0 ;;
esac
printf '{}\n200'
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

C() { # C <box> <cursor> <updated_at> <lag> <stale>
  printf '{"box":"%s","cursor":%s,"updated_at":"%s","lag":%s,"stale":%s}' "$1" "$2" "$3" "$4" "$5"
}
cursors() {
  printf '{"max_id":60001,"lag_rows":10000,"lag_s":3600,"cursors":[%s],"as_of":"2026-10-15T08:00:00Z"}' \
    "$(printf '%s,' "$@" | sed 's/,$//')" > "$CURSOR_JSON"
}
reset() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  : > "$HARNESS_ALERTS"; rm -f "$HARNESS"/flags/alerted-doorbell-* "$HARNESS"/flags/alerted-jobs-client-*
  rm -f "$CURSOR_DOWN" "$CURSOR_500" "$HARNESS/logs/doorbell-coverage-check.log" "$HARNESS/logs/jobs-client.log"
}
run() { OUT=$("$SUT" "$@" 2>&1); RC=$?; }
cursor_alerts() { grep -c '\[doorbell\] the wake cursor of box' "$HARNESS_ALERTS" 2>/dev/null; return 0; }
lanelog() { cat "$HARNESS/logs/doorbell-coverage-check.log" 2>/dev/null; }
reads() { [ -f "$T/calls/cursor" ] && wc -l < "$T/calls/cursor" | tr -d ' ' || echo 0; }

# ── 1. two stale boxes -> two lines naming each; a stale:false box -> none ──
reset
cursors "$(C project-6 1000 2026-10-14T20:00:00Z 59001 true)" \
        "$(C project-1 40000 2026-10-15T05:00:00Z 20001 true)" \
        "$(C hub 59990 2026-10-15T07:59:00Z 11 false)"
run
[ "$RC" = 0 ] && ok || bad "1 rc=$RC: $OUT"
[ "$(reads)" = 1 ] && ok || bad "1 want one cursor read, got $(reads)"
[ "$(cursor_alerts)" = 2 ] && ok || bad "1 want 2 cursor alerts, got $(cursor_alerts): $(cat "$HARNESS_ALERTS")"
grep -q 'box project-6 is 59001 wakes behind .* since 2026-10-14T20:00:00Z' "$HARNESS_ALERTS" && ok \
  || bad "1 the project-6 line lacks its lag or time: $(cat "$HARNESS_ALERTS")"
grep -q 'box project-1 is 20001 wakes behind' "$HARNESS_ALERTS" && ok || bad "1 no project-1 line: $(cat "$HARNESS_ALERTS")"
grep -q 'stop or fix the wake-loop on project-6' "$HARNESS_ALERTS" && ok || bad "1 the line names no action"
grep -q 'box hub ' "$HARNESS_ALERTS" && bad "1 a stale:false box alerted" || ok
lanelog | grep -q 'cursor-lag stale=2' && ok || bad "1 no cursor-lag log line: $(lanelog)"
case "$OUT" in *"checked=1 missing=0 unreadable=0 ringing=1"*) ok ;; *) bad "1 the summary line changed — $OUT" ;; esac
case "$OUT" in *"doorbell armed (ringing, last 2026-10-15T07:00:00Z)"*) ok ;; *) bad "1 the ringing line — $OUT" ;; esac

# ── 2. a second run the same day -> no new line ──
run
[ "$(cursor_alerts)" = 2 ] && ok || bad "2 a second run re-alerted: $(cursor_alerts)"
[ "$(reads)" = 2 ] && ok || bad "2 the second run did not read the cursors"

# ── 3. a worker 500 and an outage -> 0 alerts, one LOG line each, rc unchanged ──
for KIND in 500 down; do
  reset; cursors "$(C project-6 1000 2026-10-14T20:00:00Z 59001 true)"
  if [ "$KIND" = 500 ]; then : > "$CURSOR_500"; else : > "$CURSOR_DOWN"; fi
  run
  [ "$RC" = 0 ] && ok || bad "3 $KIND rc=$RC"
  [ "$(cursor_alerts)" = 0 ] && ok || bad "3 $KIND a failed read alerted: $(cat "$HARNESS_ALERTS")"
  [ "$(lanelog | grep -c 'cursor-lag check failed (worker did not answer)')" = 1 ] && ok \
    || bad "3 $KIND want one failed LOG line: $(lanelog)"
done

# ── 4. a 200 with no cursors array is a failed read, never "nothing stale" ──
reset; echo '{"max_id":5}' > "$CURSOR_JSON"
run
[ "$(cursor_alerts)" = 0 ] && ok || bad "4 alerted on a malformed answer"
lanelog | grep -q 'cursor-lag check failed' && ok || bad "4 a malformed answer read as success: $(lanelog)"

# ── 5. a --repo run never reads the cursors ──
reset; cursors "$(C project-6 1000 2026-10-14T20:00:00Z 59001 true)"
run --repo Test/armed
[ "$(reads)" = 0 ] && ok || bad "5 a --repo run read the cursors"
[ "$(cursor_alerts)" = 0 ] && ok || bad "5 a --repo run alerted"

echo "doorbell-cursor-lag.bh-6799: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
