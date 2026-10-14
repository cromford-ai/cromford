#!/bin/bash
# tests/routing-flip-checklist.bh-1627-test.sh — BH-1627: the four checks the
# `routing_rows` flip waits on (BH-1027), as behaviour:
#   1. an orphan flags/fly-pool-<p> (no builder-fly-<p>) is not a pool to the client;
#   2. an EMPTY flags/fly-pool-app-<p> is "no pool" to fleet-propagate's glob AND fp_has_pool;
#   3. with the knob on, one process asks the worker for routing at most once;
#   4. bin/routing-flip-preflight.sh probes /api/routing read-only and gates the flip.
# Driven through the REAL scripts and helpers against a stubbed curl.
# Run from anywhere: tests/routing-flip-checklist.bh-1627-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v git >/dev/null || { echo "jq/git missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/bin/lib/jobs" "$H/env" "$H/flags" "$T/fakebin" "$T/rows"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
[ -f "$DIR/bin/routing-flip-preflight.sh" ] && cp "$DIR/bin/routing-flip-preflight.sh" "$H/bin/"
[ -f "$DIR/bin/routing-seed-rows.sh" ] && cp "$DIR/bin/routing-seed-rows.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
bash -n "$DIR/bin/lib/jobs/routing.sh" || exit 1   # modules under test, named for bin/test-impact.sh
[ -f "$DIR/bin/routing-flip-preflight.sh" ] && { bash -n "$DIR/bin/routing-flip-preflight.sh" || exit 1; }
[ -f "$DIR/bin/routing-seed-rows.sh" ] && { bash -n "$DIR/bin/routing-seed-rows.sh" || exit 1; }
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
chmod +x "$H/bin"/*.sh
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
x       Org/x       https://x.example  /api/board 2 box-x 192.0.2.1
y       Org/y       -                  -          4 box-y 192.0.2.2
z       Org/z       -                  -          4 box-y 192.0.2.2
EOF

# Fake curl (FIXTURE worker). Rows in $ROWS/<p>.json; knob in $SETTING_JSON.
# CURL_MODE: ok | down | http401 | http500.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  http401) printf '{"error":"unauthorized"}\n401\n'; exit 0 ;;
  http500) printf 'error code: 1101\n500\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/routing)
    [ "${CURL_MODE:-ok}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    p=$(printf '%s' "$BODY" | jq -r .project); printf '%s' "$BODY" > "$ROWS/$p.json"
    printf '{"routing":%s}\n200\n' "$BODY" ;;
  "GET "*/api/routing)
    printf '{"routing":['; first=1
    for f in "$ROWS"/*.json; do [ -f "$f" ] || continue; [ $first = 1 ] || printf ','; first=0; cat "$f"; done
    printf '],"as_of":"2026-09-24T00:00:00Z"}\n200\n' ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
CURL
for s in ssh rsync gh; do printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; done
chmod +x "$T/fakebin"/*

knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null> <halted>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":%s,"updated_at":"2026-09-24T00:00:00Z"}' "$1" "$2" "$app" "$4" > "$T/rows/$1.json"
}
reset() { rm -f "$H"/flags/* "$T"/rows/* "$T/req.log"; return 0; }
routing_reqs() { if [ -f "$T/req.log" ]; then grep -cE '/api/routing(/|$)' "$T/req.log"; else echo 0; fi; }
snap() { ( cd "$H/flags" && find . -type f -printf '%p %s %T@\n' | sort ); }
ENVS="HARNESS=$H JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret SETTING_JSON=$T/setting.json ROWS=$T/rows REQ_SINK=$T/req.log FLEET_CONF=$H/fleet.conf JOBS_RETRIES=0"
envrun() { env $ENVS CURL_MODE="${CURL_MODE:-ok}" PATH="$T/fakebin:$PATH" "$@"; }

# The point readers as they stand in the real files.
extract() { grep -m1 "^$2() {" "$DIR/$1"; }
BRP=$(extract bin/blocked-resolver.sh br_pool_routed); POS=$(extract bin/pr-owner-sweep.sh pos_pool_routed)
FPH=$(extract bin/fleet-propagate.sh fp_has_pool)
[ -n "$BRP" ] && [ -n "$POS" ] && [ -n "$FPH" ] || bad "br_pool_routed / pos_pool_routed / fp_has_pool missing from the real scripts"
point() { # point <expr...> with the client loaded
  local src='. "$H/bin/jobs-client.sh"'
  envrun H="$H" MC_H="$H" bash -c "$src; $BRP; $POS; $FPH; mc_log(){ :; }; . <(sed -n '/^mc_pool_rebase_enabled() {/,/^}/p' '$DIR/bin/lib/mc/rebase.sh'); $*" 2>/dev/null
}

# Scratch origin one fleet-path commit ahead, so propagate --check reaches the pools listing.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q -b main "$T/origin" 2>/dev/null || { git init -q "$T/origin"; git -C "$T/origin" checkout -q -b main; }
mkdir -p "$T/origin/bin"; echo v1 > "$T/origin/bin/run-build.sh"
git -C "$T/origin" add -A && git -C "$T/origin" commit -qm init
git clone -q "$T/origin" "$T/checkout"
echo v2 > "$T/origin/bin/run-build.sh"; git -C "$T/origin" commit -qam v2
propagate() {
  envrun HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/fakebin:/usr/bin:/bin:/usr/local/bin" bash "$H/bin/fleet-propagate.sh" --check 2>/dev/null
}
pools_of() { sed -n '/^  pools:/,/^  crontab:/p' | grep -o '^    [A-Za-z0-9_-]*:' | tr -d ' :' | sort | tr '\n' ' '; }

# --- A1. orphan fly-pool-x: the client (always loaded on the hub) says NOT pool --
# The bare-file fallback (no client: fixtures, client-less boxes) keeps its legacy
# one-file test; the live answer is the client's, knob off or on, and no row can
# produce the orphan state. bin/routing-flip-preflight.sh names it on a box (A6).
reset; knob off; : > "$H/flags/fly-pool-x"
point 'br_pool_routed x' && bad "A1: client, knob off: an orphan fly-pool-x must not be pool-routed (br)" || ok
point 'pos_pool_routed x' && bad "A1: client, knob off: an orphan fly-pool-x must not be pool-routed (pos)" || ok
[ "$(point 'routing_builder x')" = local ] && ok || bad "A1: routing_builder on an orphan fly-pool-x must answer local (got $(point 'routing_builder x'))"
reset; knob on; : > "$H/flags/fly-pool-x"
point 'br_pool_routed x' && bad "A1: client, knob on, no row: the orphan must still not be pool-routed" || ok
reset; knob on; row x pool harness-pool-x 0
point 'br_pool_routed x' && [ -f "$H/flags/builder-fly-x" ] && [ -f "$H/flags/fly-pool-x" ] && ok || bad "A1: a pool row writes BOTH files, so rows never make an orphan"
reset; knob off; : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"
point 'br_pool_routed x' && point 'pos_pool_routed x' && ok || bad "A1: builder-fly-x + fly-pool-x must stay pool-routed"

# --- A2. empty fly-pool-app-x: the POOLS glob agrees with fp_has_pool ----------
reset; knob off; : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"; : > "$H/flags/fly-pool-app-x"
echo harness-pool-y > "$H/flags/fly-pool-app-y"
[ "$(propagate | pools_of)" = "y " ] && ok || bad "A2: propagate --check must list pool y only, never the empty-app x (got: $(propagate | pools_of))"
point 'fp_has_pool x' && bad "A2: fp_has_pool x (empty app) must be false with the client" || ok
point 'REBASE_ON_POOL=1 mc_pool_rebase_enabled x' && bad "A2: mc_pool_rebase_enabled x (empty app) must be rc 1 with the client" || ok
point 'fp_has_pool y' && point 'REBASE_ON_POOL=1 mc_pool_rebase_enabled y' && ok || bad "A2: a named app y must stay a pool"
reset; knob on; row x pool harness-pool-x 0; : > "$H/flags/fly-pool-app-z"
[ "$(propagate | pools_of)" = "x " ] && ok || bad "A2: knob on: the row's pool x is listed, the empty z is not (got: $(propagate | pools_of))"
[ "$(routing_reqs)" = 1 ] && ok || bad "A2: knob on: propagate --check must cost ONE routing request, fp_has_pool included (sent $(routing_reqs))"

# --- A3. knob on: one process asks for routing at most once ---------------------
reset; knob on; row x pool harness-pool-x 0; row y fly1 null 0; row z local null 1
point 'routing_sync_all; routing_builder x; routing_builder x; routing_pool_app x; routing_builder y; routing_halted z' >/dev/null
[ "$(routing_reqs)" = 1 ] && ok || bad "A3: sync_all + 5 reads over 3 projects must send exactly 1 routing request (sent $(routing_reqs): $(grep routing "$T/req.log" | tr '\n' ';'))"
[ -f "$H/flags/builder-fly-x" ] && [ "$(cat "$H/flags/fly-pool-app-x")" = harness-pool-x ] && [ -f "$H/flags/pool-halt-z" ] && ok || bad "A3: the one sync must still apply every row"
reset; knob on; row x pool harness-pool-x 0
point 'routing_builder x; routing_builder x; routing_pool_app x' >/dev/null
[ "$(routing_reqs)" = 1 ] && ok || bad "A3: 3 reads of one project must send 1 routing request (sent $(routing_reqs))"
reset; knob on; row x pool harness-pool-x 0; : > "$H/flags/builder-fly-y"; BEFORE=$(snap)
CURL_MODE=down point 'routing_sync_all; routing_builder x; routing_builder y; routing_pool_app x; routing_halted x' >/dev/null
[ "$(routing_reqs)" = 1 ] && ok || bad "A3: outage must cost ONE attempt per process (sent $(routing_reqs))"
[ "$BEFORE" = "$(snap | grep -v alerted-jobs-client)" ] && ok || bad "A3: outage must leave flags/ as it was"
reset; knob on; CURL_MODE=down point 'routing_builder x; routing_builder x; routing_builder y' >/dev/null
[ "$(routing_reqs)" = 2 ] && ok || bad "A3: without sync_all an outage costs one attempt per PROJECT (sent $(routing_reqs))"
reset; knob off; point 'routing_sync_all; routing_builder x; routing_builder y' >/dev/null
[ "$(routing_reqs)" = 0 ] && ok || bad "A3: knob off still sends no routing request (sent $(routing_reqs))"

# --- A4. the resolver syncs once per tick, after its off-switch ------------------
BR="$DIR/bin/blocked-resolver.sh"
# The off-switch is either the one-liner or (BH-2038, which answers a --fix-here
# caller before exiting) an `if flag_on blocked-resolver-disabled; then … fi`
# block; the sync must follow the block's `fi`, so OFF is that line. BH-2435
# reads the switch through lane_switch (settings row first) instead of flag_on.
OFF=$(grep -nE '^(flag_on|lane_switch) blocked-resolver-disabled && exit 0' "$BR" | head -1 | cut -d: -f1)
[ -n "$OFF" ] || OFF=$(awk '/^if (flag_on|lane_switch) blocked-resolver-disabled; then/{f=1} f&&/^fi$/{print NR; exit}' "$BR")
SYNC=$(grep -n '^command -v routing_sync_all' "$BR" | cut -d: -f1)
[ -n "$OFF" ] && [ "$(printf '%s\n' "$SYNC" | grep -c .)" = 1 ] && [ "${SYNC:-0}" -gt "${OFF:-0}" ] \
  && ok || bad "A4: blocked-resolver must run exactly one top-level routing_sync_all, after its off-switch (off=$OFF sync=$SYNC)"
# Mutation: a routing.sh without the memo sends one request per reader call.
reset; knob on; row x pool harness-pool-x 0
sed -e '/_routing_memo_get /d' -e '/^  \[ -n "\$_ROUTING_ALL_RC" \]/d' "$DIR/bin/lib/jobs/routing.sh" > "$H/bin/lib/jobs/routing.sh"
point 'routing_builder x; routing_builder x; routing_pool_app x' >/dev/null
[ "$(routing_reqs)" -gt 1 ] && ok || bad "A4: mutant routing.sh (memo removed) must send more than 1 request — the count proves the memo"
cp "$DIR/bin/lib/jobs/routing.sh" "$H/bin/lib/jobs/routing.sh"

# --- A5-A8. bin/routing-flip-preflight.sh ----------------------------------------
PF="$H/bin/routing-flip-preflight.sh"
preflight() { envrun bash "$PF" 2>&1; }
if [ ! -f "$PF" ]; then bad "A5-A8: bin/routing-flip-preflight.sh does not exist"; else
  # A5 clean: files agree with the rows.
  reset; knob off; row x pool harness-pool-x 0; row y fly1 null 0; row z local null 0
  : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"; echo harness-pool-x > "$H/flags/fly-pool-app-x"; : > "$H/flags/builder-fly-y"
  BEFORE=$(snap); OUT=$(preflight); RC=$?
  [ "$RC" = 0 ] && ok || bad "A5: clean box must pass (rc=$RC): $OUT"
  for c in 1 2 3 4 5; do grep -q "^\[PASS\] $c " <<<"$OUT" && ok || bad "A5: check $c must print a PASS line: $OUT"; done
  grep -q 'routing_rows=off' <<<"$OUT" && ok || bad "A5: must print the knob's current value"
  grep -q 'http=200 rows=3' <<<"$OUT" && ok || bad "A5: must record the live probe's status and row count"
  # A8 read-only (knob off here, knob on below).
  [ "$BEFORE" = "$(snap)" ] && ok || bad "A8: preflight must leave flags/ byte-identical"
  NONGET=$(grep -v '^GET ' "$T/req.log"); [ -z "$NONGET" ] && ok || bad "A8: preflight sent a non-GET: $NONGET"
  # A6 orphan, empty app, drifting row.
  reset; knob off; row x pool harness-pool-x 1
  : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"; echo harness-pool-x > "$H/flags/fly-pool-app-x"
  : > "$H/flags/fly-pool-y"; : > "$H/flags/builder-fly-z"; : > "$H/flags/fly-pool-z"; : > "$H/flags/fly-pool-app-z"
  OUT=$(preflight); RC=$?
  [ "$RC" = 1 ] && ok || bad "A6: orphan/empty/drift must fail (rc=$RC)"
  grep -q '^\[FAIL\] 1 .*fly-pool-y' <<<"$OUT" && ok || bad "A6: check 1 must name the orphan fly-pool-y: $OUT"
  grep -q '^\[FAIL\] 2 .*fly-pool-app-z' <<<"$OUT" && ok || bad "A6: check 2 must name the empty fly-pool-app-z: $OUT"
  grep -q '^\[FAIL\] 4 .*pool-halt-x' <<<"$OUT" && ok || bad "A6: the row drift (x halted=1, no file) must be named: $OUT"
  # A7 the live probe failing.
  for m in http401 http500 down; do
    reset; knob off; OUT=$(CURL_MODE=$m preflight); RC=$?
    [ "$RC" = 1 ] && grep -q '^\[FAIL\] 4 .*http=' <<<"$OUT" && ok || bad "A7: probe $m must fail check 4 with its http= status (rc=$RC): $OUT"
  done
  # A8 read-only with the knob ON and a row that disagrees with the files.
  reset; knob on; row x local null 0; : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"
  BEFORE=$(snap); OUT=$(preflight); RC=$?
  [ "$BEFORE" = "$(snap)" ] && ok || bad "A8: knob on — preflight must still write nothing to flags/"
  [ "$RC" = 1 ] && grep -q 'routing_rows=on' <<<"$OUT" && ok || bad "A8: knob on + drift must fail and say the knob is on (rc=$RC): $OUT"
  NONGET=$(grep -v '^GET ' "$T/req.log"); [ -z "$NONGET" ] && ok || bad "A8: knob on — preflight sent a non-GET: $NONGET"
fi

# --- A9-A11. the empty table: preflight check 5, then bin/routing-seed-rows.sh ------
SEED="$H/bin/routing-seed-rows.sh"
seed() { envrun bash "$SEED" "$@" 2>&1; }
puts() { if [ -f "$T/req.log" ]; then grep -c '^PUT ' "$T/req.log"; else echo 0; fi; }
hub_files() { # x pool (halted), y fly1, z local — a real hub's shape
  : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"; echo harness-pool-x > "$H/flags/fly-pool-app-x"; : > "$H/flags/pool-halt-x"
  : > "$H/flags/builder-fly-y"; }
if [ ! -f "$SEED" ]; then bad "A9-A11: bin/routing-seed-rows.sh does not exist"; else
  # A9 empty table: the flip would be a no-op, so check 5 fails and says how to seed.
  reset; knob off; hub_files
  OUT=$(preflight); RC=$?
  [ "$RC" = 1 ] && grep -q '^\[FAIL\] 5 .*missing x y z.*routing-seed-rows.sh --apply' <<<"$OUT" \
    && ok || bad "A9: an empty table must fail check 5, name x y z and the seed command (rc=$RC): $OUT"
  # A10 dry run: prints, PUTs nothing, touches nothing.
  BEFORE=$(snap); OUT=$(seed); RC=$?
  [ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$BEFORE" = "$(snap)" ] && ok || bad "A10: dry run must PUT nothing and write nothing (rc=$RC puts=$(puts)): $OUT"
  grep -q '^would seed x builder=pool pool_app=harness-pool-x halted=1$' <<<"$OUT" \
    && grep -q '^would seed y builder=fly1 pool_app=- halted=0$' <<<"$OUT" \
    && grep -q '^would seed z builder=local pool_app=- halted=0$' <<<"$OUT" && ok || bad "A10: dry run must name each derived row: $OUT"
  # A10 apply: 3 PUTs, files byte-identical (mtimes too), then the preflight is READY.
  rm -f "$T/req.log"; OUT=$(seed --apply); RC=$?
  [ "$RC" = 0 ] && [ "$(puts)" = 3 ] && ok || bad "A10: --apply must PUT exactly 3 rows (rc=$RC puts=$(puts)): $OUT"
  [ "$BEFORE" = "$(snap)" ] && ok || bad "A10: --apply must leave flags/ byte-identical"
  [ "$(jq -r '[.builder, .pool_app, .halted] | join(",")' "$T/rows/x.json")" = "pool,harness-pool-x,1" ] \
    && [ "$(jq -r .builder "$T/rows/z.json")" = local ] && ok || bad "A10: the stored rows must say what the files say"
  OUT=$(preflight); RC=$?
  [ "$RC" = 0 ] && [[ "$OUT" == *$'\n''[PASS] 5 one row per fleet project: 3/3'* ]] && [[ "$OUT" == *$'\n''RESULT: READY'* ]] \
    && ok || bad "A10: after the seed the preflight must be READY (rc=$RC): $OUT"
  # A10 idempotent: a re-run PUTs nothing.
  rm -f "$T/req.log"; OUT=$(seed --apply); RC=$?
  [ "$RC" = 0 ] && [ "$(puts)" = 0 ] && grep -q 'already matching 3' <<<"$OUT" && ok || bad "A10: re-run must be a no-op (rc=$RC puts=$(puts)): $OUT"
  # A10 and the flip that follows is invisible: knob on, every reader answers as before.
  knob on; BEFORE=$(snap)
  [ "$(point 'routing_sync_all; routing_builder x; routing_builder y; routing_builder z' | tr '\n' ' ')" = "pool fly1 local " ] \
    && [ "$BEFORE" = "$(snap)" ] && ok || bad "A10: after seed + flip the readers must answer pool/fly1/local and move no file"
  # A11 refusals: whole run, zero PUTs.
  for bad_state in orphan emptyapp strayapp; do
    reset; knob off; hub_files
    case $bad_state in
      orphan) : > "$H/flags/fly-pool-z"; want="fly-pool-z" ;;
      emptyapp) : > "$H/flags/fly-pool-y"; : > "$H/flags/fly-pool-app-y"; want="fly-pool-app-y" ;;
      strayapp) echo app-z > "$H/flags/fly-pool-app-z"; want="fly-pool-app-z" ;;
    esac
    OUT=$(seed --apply); RC=$?
    [ "$RC" = 1 ] && [ "$(puts)" = 0 ] && [[ "$OUT" == *REFUSED* ]] && [[ "$OUT" == *"$want"* ]] \
      && ok || bad "A11 $bad_state: must refuse the whole run naming $want, zero PUTs (rc=$RC puts=$(puts)): $OUT"
  done
  reset; knob off; hub_files; row y local null 0
  OUT=$(seed --apply); RC=$?
  [ "$RC" = 1 ] && [ "$(puts)" = 0 ] && [ "$(jq -r .builder "$T/rows/y.json")" = local ] && grep -q 'y: existing row local|' <<<"$OUT" \
    && ok || bad "A11: a differing existing row must be named and never overwritten (rc=$RC puts=$(puts)): $OUT"
  reset; knob off; hub_files; OUT=$(CURL_MODE=putfail seed --apply); RC=$?
  [ "$RC" = 1 ] && grep -q '^FAILED x ' <<<"$OUT" && ok || bad "A11: a failed PUT must be reported and fail the run (rc=$RC): $OUT"

  # --- BH-2010 (the #1989 re-review follow-ups) ---------------------------------
  # A12 every seeded row is AUDITED: the PUT carries actor routing-seed and a reason.
  reset; knob off; hub_files; OUT=$(seed --apply); RC=$?
  [ "$RC" = 0 ] && [ "$(jq -r .actor "$T/rows/x.json")" = routing-seed ] && [ -n "$(jq -r '.reason // empty' "$T/rows/x.json")" ] \
    && [ "$(jq -r .actor "$T/rows/z.json")" = routing-seed ] && ok || bad "A12: seeded PUTs must carry actor routing-seed and a reason (rc=$RC): $(cat "$T/rows/x.json" 2>/dev/null)"
  # A13 a DRY RUN during a worker outage raises no daily alert: it fails (the
  # list read is its first step) but leaves no alerted-jobs-client flag and no ALERTS line.
  reset; knob off; hub_files; rm -f "$H/logs/ALERTS.log"
  OUT=$(CURL_MODE=down seed); RC=$?
  ls "$H"/flags/alerted-jobs-client-* >/dev/null 2>&1 && bad "A13: a dry run with the worker down must not set the daily alerted-jobs-client flag" || ok
  [ ! -s "$H/logs/ALERTS.log" ] && ok || bad "A13: a dry run with the worker down must not write ALERTS.log: $(cat "$H/logs/ALERTS.log")"
  [ "$RC" = 1 ] && ok || bad "A13: the dry run must still fail on the unreadable list (rc=$RC): $OUT"
  # A14 a pool_app name that fails validation refuses the WHOLE run, before any PUT.
  reset; knob off; hub_files; echo '..' > "$H/flags/fly-pool-app-x"
  OUT=$(seed --apply); RC=$?
  [ "$RC" = 1 ] && [ "$(puts)" = 0 ] && [[ "$OUT" == *REFUSED* ]] && [[ "$OUT" == *"x: pool_app"* ]] \
    && ok || bad "A14: an invalid pool_app must refuse the whole run naming x, zero PUTs (rc=$RC puts=$(puts)): $OUT"
fi

echo "routing-flip-checklist.bh-1627: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
