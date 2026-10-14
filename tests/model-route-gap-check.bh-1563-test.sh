#!/bin/bash
# tests/model-route-gap-check.bh-1563-test.sh — bin/model-route-gap-check.sh,
# driven for real against a stubbed curl, the same idiom
# tests/model-route-lib.bh-1510-test.sh uses and for the same reason: the script
# under test is the REAL one, copied into a scratch harness, so a bug in the
# detector shows up here instead of only on the hub at 04:35Z.
#
# WHAT IT IS FOR. A (scope, role) in model_routes whose rows do not start at
# position 0 is INVISIBLE: bin/lib/model-route.sh drops it (a project scope
# falls back to the hub ladder, a hub scope becomes "no route"), so nobody
# resolving a model ever learns the rows are there. The lib's own runtime
# norung0 branch cannot page for such a scope either — it only fires when
# somebody resolves that exact role, and the worker has already resolved past
# the gap by then. This lane is the sweep that reads GET /api/model-routes's
# `gaps` array and pages once per gapped scope per UTC day.
#
# THE PROPERTIES UNDER TEST:
#   1. two gapped scopes (one project, one hub) -> exactly two ALERTS lines,
#      each naming its role, its rungs and a /models repair URL; the project
#      one names its project;
#   2. the reservoir: a second run the same day writes NO new line, and the
#      flag files it shares with bin/lib/model-route.sh are on disk;
#   3. no gaps -> no ALERTS line at all, and one summary line saying gapped=0;
#   4. the worker unreachable -> ONE log line, NO [model-route] ALERTS line
#      from this script (jobs-client's own daily reservoir already pages a
#      worker outage), rc 0;
#   5. flags/all-off -> the lane gate exits 0 having asked the worker nothing.
#
# Everything is asserted on ARTIFACTS — logs/ALERTS.log, flags/, the lane log,
# the request sink — never on the script's source text.
#
# The clock is read ONCE, into NOW, and every date-shaped assertion uses it
# (bin/test-determinism-lint.sh).
#
# Run from anywhere: bash tests/model-route-gap-check.bh-1563-test.sh
#   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date -u +%Y%m%d)

mkdir -p "$T/logs" "$T/flags" "$T/state" "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/model-route-gap-check.sh" "$T/bin/model-route-gap-check.sh" 2>/dev/null
chmod +x "$T/bin/model-route-gap-check.sh" 2>/dev/null
cp "$DIR/bin/jobs-client.sh"     "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/model-route.sh" "$T/bin/lib/model-route.sh"
cp "$DIR/bin/lib/lane-gate.sh"   "$T/bin/lib/lane-gate.sh"
cp "$DIR"/bin/lib/jobs/*.sh      "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# GET /api/model-routes answers from $HARNESS/list.json; EVERYTHING else is a
# 404, which bin/lib/jobs/req.sh reads as a real answer (rc 2) rather than an
# outage — so the lane gate's own flag reads and liveness posts cost nothing
# and write no ALERTS line of their own. CURL_MODE=down is the outage.
# The emitted shape is `<body>\n<status>`, which is what `curl -w '\n%{http_code}'`
# produces and what _jobs_req parses.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
esac
case "$URL" in
  *"/api/model-routes")
    if [ -s "$HARNESS/list.json" ]; then cat "$HARNESS/list.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

REQ_SINK="$T/req.log"
run() { # run [args...] -> the real script, rc as the caller's rc
  ( env PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
        JOBS_URL=https://jobs.invalid REQ_SINK="$REQ_SINK" ${EXTRA_ENV:-} \
        bash "$T/bin/model-route-gap-check.sh" "$@" )
}
# Only THIS script's alerts: _mr_alert_once tags every line `[model-route]`, and
# a worker outage also puts a `[jobs-client]` line in the same file (case 4).
# A MISSING ALERTS.log IS ZERO, not the empty string `grep -c` leaves behind
# when it cannot open the file — otherwise "nothing was written" would fail the
# very assertions that exist to prove nothing was written.
mr_lines() {
  local n
  n=$(grep -c '\[model-route\]' "$T/logs/ALERTS.log" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
LANELOG="$T/logs/model-route-gap-check.log"

# --- 1. two gapped scopes -> exactly two alerts, each with role, rungs, URL ---
cat > "$T/list.json" <<'JSON'
{"project":null,
 "roles":[{"role":"build.execute","ladder":[],"source":"hub","gapped":false},
          {"role":"review.pr","ladder":[],"source":"none","gapped":true},
          {"role":"plan.write","ladder":[],"source":"hub","gapped":false}],
 "gaps":[{"project":"project-3","role":"build.execute","positions":[2]},
         {"project":null,"role":"review.pr","positions":[1,3]}],
 "as_of":"2026-09-23T04:35:00Z"}
JSON
rm -f "$T/logs/ALERTS.log" "$LANELOG" "$T"/flags/alerted-model-route-*
run --quiet >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "1a the lane exited $RC, wanted 0 (a detector must never fail a tick)"
[ "$(mr_lines)" = "2" ] && ok || bad "1b wanted 2 [model-route] ALERTS lines, got $(mr_lines): $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
PROJ_LINE=$(grep '\[model-route\]' "$T/logs/ALERTS.log" 2>/dev/null | grep 'build.execute' || true)
HUB_LINE=$(grep '\[model-route\]' "$T/logs/ALERTS.log" 2>/dev/null | grep 'review.pr' || true)
if [ -n "$PROJ_LINE" ] \
   && grep -q 'project-3' <<<"$PROJ_LINE" \
   && grep -q '2' <<<"$PROJ_LINE" \
   && grep -q '/models/build.execute' <<<"$PROJ_LINE"; then ok
else bad "1c the project gap's line must name the role, the project, the rung and a /models URL: '$PROJ_LINE'"; fi
if [ -n "$HUB_LINE" ] \
   && grep -q '1,3' <<<"$HUB_LINE" \
   && grep -q '/models/review.pr' <<<"$HUB_LINE"; then ok
else bad "1d the hub gap's line must name the role, the rungs and a /models URL: '$HUB_LINE'"; fi
grep -q 'gapped=2' "$LANELOG" 2>/dev/null && ok || bad "1e wanted a gapped=2 summary in $LANELOG: $(cat "$LANELOG" 2>/dev/null)"
grep -q 'checked=3' "$LANELOG" 2>/dev/null && ok || bad "1f wanted checked=3 (the response's roles length) in $LANELOG: $(cat "$LANELOG" 2>/dev/null)"

# --- 2. the daily reservoir: a second run the same day pages nothing ---------
run --quiet >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "2a the second run exited $RC, wanted 0"
[ "$(mr_lines)" = "2" ] && ok || bad "2b a second run the same day must add no line, got $(mr_lines) total"
# The flag key is bin/lib/model-route.sh's own, so the lib's runtime branch and
# this sweep share ONE reservoir per scope per day.
[ -f "$T/flags/alerted-model-route-build.execute-norung0-project-3-$NOW" ] && ok \
  || bad "2c no reservoir flag for the project scope: $(ls "$T"/flags 2>/dev/null | tr '\n' ' ')"
[ -f "$T/flags/alerted-model-route-review.pr-norung0-$NOW" ] && ok \
  || bad "2d no reservoir flag for the hub scope: $(ls "$T"/flags 2>/dev/null | tr '\n' ' ')"

# --- 3. no gaps -> no alert at all, and a summary that says so ---------------
cat > "$T/list.json" <<'JSON'
{"project":null,
 "roles":[{"role":"build.execute","ladder":[],"source":"hub","gapped":false},
          {"role":"review.pr","ladder":[],"source":"hub","gapped":false}],
 "gaps":[],"as_of":"2026-09-23T04:35:00Z"}
JSON
rm -f "$T/logs/ALERTS.log" "$LANELOG" "$T"/flags/alerted-model-route-*
run --quiet >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "3a the lane exited $RC, wanted 0"
[ "$(mr_lines)" = "0" ] && ok || bad "3b a clean sweep must page nothing, got: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
grep -q 'gapped=0' "$LANELOG" 2>/dev/null && ok || bad "3c wanted one gapped=0 summary line in $LANELOG: $(cat "$LANELOG" 2>/dev/null)"

# --- 4. worker down -> one log line, no alert from THIS script, rc 0 ---------
rm -f "$T/logs/ALERTS.log" "$LANELOG" "$T"/flags/alerted-model-route-*
OUT=$(EXTRA_ENV="CURL_MODE=down" run --quiet 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "4a an unreachable worker must not fail the tick: rc=$RC out='$OUT'"
[ "$(mr_lines)" = "0" ] && ok \
  || bad "4b a detector must not page on its own transport (jobs-client already does): $(grep '\[model-route\]' "$T/logs/ALERTS.log" 2>/dev/null)"
grep -qi 'unreachable' "$LANELOG" 2>/dev/null && ok \
  || bad "4c wanted one 'unreachable' line in $LANELOG, got: $(cat "$LANELOG" 2>/dev/null)"

# --- 5. flags/all-off -> the gate exits 0 having read nothing ----------------
# The sink is fresh, so ANY /api/model-routes request in it is the lane body
# running past its own gate. The gate's own flag reads are a different path and
# are not what this asserts on.
cat > "$T/list.json" <<'JSON'
{"project":null,
 "roles":[{"role":"build.execute","ladder":[],"source":"none","gapped":true}],
 "gaps":[{"project":null,"role":"build.execute","positions":[2]}],
 "as_of":"2026-09-23T04:35:00Z"}
JSON
rm -f "$T/logs/ALERTS.log" "$LANELOG" "$T"/flags/alerted-model-route-* "$REQ_SINK"
: > "$T/flags/all-off"
run --quiet >/dev/null 2>&1; RC=$?
rm -f "$T/flags/all-off"
[ "$RC" = 0 ] && ok || bad "5a a gated tick must exit 0, got $RC"
if grep -q '/api/model-routes' "$REQ_SINK" 2>/dev/null; then
  bad "5b the lane asked the worker for routes with flags/all-off set: $(grep '/api/model-routes' "$REQ_SINK")"
else ok; fi
[ "$(mr_lines)" = "0" ] && ok || bad "5c a gated tick wrote an ALERTS line: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
[ ! -s "$LANELOG" ] && ok || bad "5d a gated tick wrote to the lane log: $(cat "$LANELOG" 2>/dev/null)"

echo "model-route-gap-check-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
