#!/bin/bash
# tests/routing-contract.bh-1369-test.sh — BH-1369 (BH-1027.0): the routing
# contract's client module, driven through the REAL bin/jobs-client.sh against
# a stubbed curl. Pins: dark launch (knob off = one settings GET, no routing request, files answer),
# row -> four derived files, outage leaves flags/ byte-identical, files-first
# write-through on routing-set, fly-pool-<p> never rewritten.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/bin/lib/jobs" "$H/env" "$H/flags" "$H/fly" "$T/fakebin" "$T/rows"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/pool-cap.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
bash -n "$DIR/bin/lib/jobs/routing.sh" || exit 1   # the module under test, named for bin/test-impact.sh
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
echo "HARNESS_SECRET=test-secret" > "$H/env/global.env"
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log" | tr -d ' '; else echo 0; fi; }

# Fake curl. Rows live in $T/rows/<project>.json (the row object); the knob is
# $SETTING_JSON. CURL_MODE: ok|down|http500|empty|old404|putfail.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  http500) printf '{"error":"boom"}\n500\n'; exit 0 ;;
  empty) printf '\n200\n'; exit 0 ;;
  old404) printf '{"error":"not found"}\n404\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/routing)
    [ "${CURL_MODE:-ok}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '{"routing":%s}\n200\n' "$BODY" ;;
  "GET "*/api/routing)
    printf '{"routing":['; first=1
    for f in "$ROWS"/*.json; do [ -f "$f" ] || continue; [ $first = 1 ] || printf ','; first=0; cat "$f"; done
    printf ']}\n200\n' ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null> <halted>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":%s,"updated_at":"2026-09-23T00:00:00Z"}' "$1" "$2" "$app" "$4" > "$T/rows/$1.json"
}
cli() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" ROWS="$T/rows" \
           REQ_SINK="$T/req.log" CURL_MODE="${CURL_MODE:-ok}" ${EXTRA_ENV:-}
    bash "$H/bin/jobs-client.sh" "$@" )
}
# The four routing files only: jobs-client's own outage marker
# (flags/alerted-jobs-client-<day>) is existing _jobs_log behaviour, not ours.
snap() { ( cd "$H/flags" && find . \( -name 'builder-fly-*' -o -name 'fly-pool-*' -o -name 'pool-halt-*' \) -printf '%p %s %T@\n' | sort ); }
F="$H/flags"

# --- 1. schema applies twice ---------------------------------------------------
if node -e 'require("node:sqlite")' 2>/dev/null; then
  node -e '
    const { DatabaseSync } = require("node:sqlite");
    const s = require("fs").readFileSync(process.argv[1], "utf8");
    const db = new DatabaseSync(":memory:"); db.exec(s); db.exec(s);
    const c = db.prepare("PRAGMA table_info(routing)").all().map(r => r.name).join(",");
    process.exit(c === "project,builder,pool_app,halted,updated_at" ? 0 : 1);' "$DIR/worker/jobs/schema.sql" 2>/dev/null \
    && ok || bad "schema.sql routing table did not apply twice with the five columns"
else echo "note: node:sqlite unavailable, case 1 skipped"; fi

# --- 2. routing-list parses to TSV -------------------------------------------
row alpha pool pool-alpha 1; row beta local null 0
OUT=$(cli routing-list); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$(printf 'alpha\tpool\tpool-alpha\t1\t2026-09-23T00:00:00Z\nbeta\tlocal\t\t0\t2026-09-23T00:00:00Z')" ] \
  && ok || bad "routing-list rc=$RC out='$OUT'"
rm -f "$T/rows"/*.json

# --- 3. dark launch ------------------------------------------------------------
rm -f "$T/req.log" "$T/setting.json"
knob off
touch "$F/builder-fly-x" "$F/fly-pool-x"; echo app-x > "$F/fly-pool-app-x"
row x fly1 null 0
EXTRA_ENV=""
[ "$(cli routing-builder x)" = pool ] && ok || bad "knob off: routing-builder x should be pool"
[ "$(cli routing-pool-app x)" = app-x ] && ok || bad "knob off: routing-pool-app x should read the file"
cli routing-halted x; [ $? = 1 ] && ok || bad "knob off: routing-halted x should be rc 1 (no halt file)"
touch "$F/pool-halt-x"; cli routing-halted x; [ $? = 0 ] && ok || bad "knob off: halt file => rc 0"; rm -f "$F/pool-halt-x"
cli routing-sync x; [ $? = 0 ] && [ -f "$F/fly-pool-x" ] && ok || bad "knob off: routing-sync must be a no-op rc 0"
[ "$(reqs)" = 5 ] && ok || bad "default config, knob off: exactly one settings GET per call (5); got $(reqs)"
[ "$(grep -Ec '/api/settings/routing_rows( |$)' "$T/req.log")" = 5 ] && ok || bad "knob off: every request must be the settings GET"
grep -q '/api/routing' "$T/req.log" && bad "knob off must make ZERO /api/routing requests" || ok
rm -f "$T/req.log"; EXTRA_ENV="ROUTING_ROWS=off"
cli routing-builder x >/dev/null; cli routing-sync x
[ "$(reqs)" = 0 ] && ok || bad "ROUTING_ROWS=off must make ZERO requests; got $(reqs)"
EXTRA_ENV=""
cli routing-rows-on; [ $? = 1 ] && ok || bad "setting off => routing-rows-on rc 1"
knob on
cli routing-rows-on; [ $? = 0 ] && ok || bad "setting on => routing-rows-on rc 0"
EXTRA_ENV="ROUTING_ROWS=off"; cli routing-rows-on; [ $? = 1 ] && ok || bad "env off overrides DB on"; EXTRA_ENV=""
[ "$(cli routing-builder x)" = fly1 ] && ok || bad "knob on, row fly1 => routing-builder fly1"
[ ! -e "$F/fly-pool-x" ] && [ ! -e "$F/fly-pool-app-x" ] && [ -f "$F/builder-fly-x" ] && ok || bad "row fly1 must leave builder-fly only"
row x local null 0; [ "$(cli routing-builder x)" = local ] && [ ! -e "$F/builder-fly-x" ] && ok || bad "row local => no builder-fly"
rm -f "$T/rows"/*.json "$F"/*

# --- 4. prefix collision -------------------------------------------------------
row project-3 pool pool-project-3 1
[ "$(cli routing-builder project-3)" = local ] && [ ! -e "$F/builder-fly-project-3" ] && [ ! -e "$F/pool-halt-project-3" ] \
  && ok || bad "row for project-3 must never answer project-3"
cli routing-get project-3 >/dev/null; [ $? = 2 ] && ok || bad "routing-get with no row must be rc 2 (404)"
[ "$(cli routing-get project-3 | jq -r .builder)" = pool ] && ok || bad "routing-get project-3 prints the row"
CURL_MODE=http500 cli routing-get project-3 >/dev/null; [ $? = 1 ] && ok || bad "routing-get on 500 must be rc 1"
rm -f "$T/rows"/*.json

# --- 5. pool with NULL app ----------------------------------------------------
echo stale > "$F/fly-pool-app-x"; row x pool null 0
[ "$(cli routing-builder x)" = pool ] && ok || bad "row pool => routing-builder pool"
OUT=$(cli routing-pool-app x); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -e "$F/fly-pool-app-x" ] && ok || bad "pool + null app: rc=$RC out='$OUT', app file must be gone"
rm -f "$F/fly-pool-x"; ( export HARNESS="$H" ROUTING_ROWS=off; bash "$H/bin/jobs-client.sh" routing-builder x ) | grep -qx fly1 \
  && ok || bad "without fly-pool-x the file answer is fly1, as caps_route says"
rm -f "$T/rows"/*.json "$F"/*

# --- 6. outage leaves flags/ byte-identical (mtimes included) -------------------
row x local null 1
touch -d "@$((NOW-3600))" "$F/builder-fly-x" "$F/fly-pool-x"; echo keep > "$F/fly-pool-app-x"; touch -d "@$((NOW-3600))" "$F/fly-pool-app-x"
for m in down http500 empty old404; do
  BEFORE=$(snap)
  CURL_MODE=$m cli routing-sync x; RC=$?
  AFTER=$(snap)
  [ "$RC" != 0 ] && [ "$BEFORE" = "$AFTER" ] && ok || bad "outage $m: rc=$RC or flags/ changed"
done
rm -f "$T/rows"/*.json "$F"/*

# --- 7. routing-set writes files first, PUT failure is rc 1 --------------------
CURL_MODE=putfail cli routing-set x pool app1 1; RC=$?
[ "$RC" = 1 ] && [ -f "$F/builder-fly-x" ] && [ -f "$F/fly-pool-x" ] && [ "$(cat "$F/fly-pool-app-x")" = app1 ] && [ -f "$F/pool-halt-x" ] \
  && ok || bad "routing-set putfail: rc=$RC or files missing"
cli routing-set x banana; [ $? != 0 ] && ok || bad "routing-set rejects builder banana"
cli routing-set ../x local; [ $? != 0 ] && [ ! -e "$H/x" ] && ok || bad "routing-set rejects a path-escaping project"
cli routing-set x local; RC=$?; [ "$RC" = 0 ] && [ -z "$(ls "$F" | grep -v "^alerted-")" ] && ok || bad "routing-set x local clears all four files (rc=$RC, left: $(ls "$F"))"
grep -q 'PUT .*/api/routing {.*"builder":"local"' "$T/req.log" && ok || bad "routing-set must PUT the row"
rm -f "$F"/*

# --- 8. fly-pool-<p> content is never rewritten --------------------------------
echo "x 4" > "$H/fly/pool-caps.conf"
echo 5 > "$F/fly-pool-x"; row x pool app1 0
cli routing-sync x; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$F/fly-pool-x")" = 5 ] && ok || bad "sync must keep fly-pool-x content (rc=$RC)"
[ "$(HARNESS="$H" POOL_AUTOSCALE=1 bash "$H/bin/pool-cap.sh" x)" = 5 ] && ok || bad "pool-cap should still print 5"
rm -f "$F/fly-pool-x"; cli routing-sync x
[ -f "$F/fly-pool-x" ] && [ ! -s "$F/fly-pool-x" ] && ok || bad "sync must create fly-pool-x empty"
[ "$(HARNESS="$H" POOL_AUTOSCALE=1 bash "$H/bin/pool-cap.sh" x)" = 4 ] && ok || bad "pool-cap with empty flag should print conf 4"
rm -f "$T/rows"/*.json "$F"/*
row a fly1 null 0; row b pool pb 1
cli routing-sync-all; RC=$?
[ "$RC" = 0 ] && [ -f "$F/builder-fly-a" ] && [ "$(cat "$F/fly-pool-app-b")" = pb ] && [ -f "$F/pool-halt-b" ] && ok || bad "routing-sync-all rc=$RC"
rm -f "$T/rows"/*.json "$F"/*

# --- 9. mutation: a knob that is always on must break the dark launch ----------
rm -f "$T/req.log"; knob off; touch "$F/builder-fly-x" "$F/fly-pool-x"; row x fly1 null 0
( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
         SETTING_JSON="$T/setting.json" ROWS="$T/rows" REQ_SINK="$T/req.log" ROUTING_ROWS=off
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  routing_rows_on() { return 0; }
  routing_builder x >/dev/null )
[ "$(reqs)" -gt 0 ] && ok || bad "mutation (knob forced on) did not make the dark-launch assertion fail"

echo "routing-contract.bh-1369: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
