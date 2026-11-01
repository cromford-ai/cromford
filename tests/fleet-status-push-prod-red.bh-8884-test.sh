#!/bin/bash
# tests/fleet-status-push-prod-red.bh-8884-test.sh — the fleet-status push
# carries the merge conductor's production-red answer in each project row
# (BH-8884, item 4 of BH-8781). The console's QUEUE cell
# (console-ui/src/lib/prod-red.js, console-ui/src/screens/Fleet.js) renders it
# as `prod: red since <time>`.
#
# The field is read with mc_prod_red_state, the reader the conductor holds on,
# so the page says red exactly when the queue is held:
#   P1 a fresh red record           -> prod {state:red,since,sha,id}
#   P2 prod_red null                -> no prod key
#   P3 a project not in vercel.conf -> no prod key
#   P4 prod_red {since:""}          -> no prod key (the reader reads green)
#   P5 a red record, snapshot stale -> state unknown, never red
#   P6 no snapshot file             -> unknown for vercel.conf projects only;
#                                      a space in generated_at still parses
#   P7 no conductor fragment        -> the push is unchanged and still sent
#   P8 the pushed P1 object         -> prodMarker text `prod: red since Oct 27 19:10Z`
# The clock is pinned with MC_PROD_RED_NOW; nothing reads the wall clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
( cd "$DIR" && scratch_install_closure bin/fleet-status-push.sh "$T" >/dev/null \
  && scratch_install_closure bin/merge-conductor.d/bh-8781-prod-red-hold.sh "$T" >/dev/null ) \
  || { echo "FAIL: cannot install the closure"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=fixture-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# Only the POST is the push; the standby GET reads nothing here.
printf '#!/bin/bash\ncase " $* " in *" -X POST "*) cat > %s/PUSH.json; echo push >> %s/CURL.calls ;; esac\n' "$T" "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
beta-os  Org/beta  https://b.example /api/board 4 box-beta
gamma-os Org/gamma https://g.example /api/board 4 box-beta
EOF
cat > "$T/vercel.conf" <<'EOF'
# <project> <teamId> <projectId> <prod-domain>
alpha-os team_fixture1 prj_fixture1 alpha.example
beta-os  team_fixture1 prj_fixture2 beta.example
EOF

NOW=1793000000
SNAP="$T/state/vercel-deploy-status.json"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# snap <generated_at> <alpha prod_red json> — the shape bin/vercel-deploy-snapshot.sh writes.
# gamma-os carries the same record but is not in vercel.conf: only the gate keeps it off.
snap() {
  jq -nc --arg g "$1" --argjson a "$2" '{generated_at:$g, projects:{
    "alpha-os":{state:"READY",prod_red:$a},
    "beta-os":{state:"READY",prod_red:null},
    "gamma-os":{state:"ERROR",prod_red:$a}}}' > "$SNAP"
}
run() {
  rm -f "$T/PUSH.json" "$T/BEAT.json" "$T/CURL.calls"
  PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" MC_PROD_RED_NOW=$NOW env "$@" \
    bash "$T/bin/fleet-status-push.sh"
}
q() { jq -c "$1" "$T/PUSH.json" 2>/dev/null; }

RED='{"since":"2026-10-27T19:10:00Z","sha":"abc12345","id":"dpl_fixture1"}'

# --- P1 / P2 / P3: a fresh snapshot ----------------------------------------
snap "$(iso $((NOW - 60)))" "$RED"
run
[ "$(q '.projects["alpha-os"].prod.state')" = '"red"' ] && ok || bad "P1: a fresh red record is state red (got: $(q '.projects["alpha-os"].prod'))"
[ "$(q '.projects["alpha-os"].prod | [.since,.sha,.id]')" = '["2026-10-27T19:10:00Z","abc12345","dpl_fixture1"]' ] \
  && ok || bad "P1: since, sha and id ride out (got: $(q '.projects["alpha-os"].prod'))"
[ "$(q '.projects["beta-os"] | has("prod")')" = false ] && ok || bad "P2: prod_red null reads green, no prod key (got: $(q '.projects["beta-os"].prod'))"
[ "$(q '.projects["gamma-os"] | has("prod")')" = false ] && ok || bad "P3: a project not in vercel.conf gets no prod key (got: $(q '.projects["gamma-os"].prod'))"
P1PROD=$(q '.projects["alpha-os"].prod')

# --- P8: the console reader renders the object the push wrote --------------
READER="$DIR/console-ui/src/lib/prod-red.js"
if command -v node >/dev/null; then
  GOT=$(node --input-type=module -e "import { prodMarker } from '$READER'; console.log(prodMarker(JSON.parse(process.argv[1])).text);" "$P1PROD" 2>&1)
  [ "$GOT" = "prod: red since Oct 27 19:10Z" ] && ok || bad "P8: prodMarker over the pushed P1 object (got: $GOT)"
else
  echo "P8: node missing — skipped"
fi

# --- P4: an empty since is not a red record ---------------------------------
snap "$(iso $((NOW - 60)))" '{"since":""}'
run
[ "$(q '.projects["alpha-os"] | has("prod")')" = false ] && ok || bad "P4: prod_red with an empty since is green (got: $(q '.projects["alpha-os"].prod'))"

# --- P5: a stale snapshot is unknown, never red -----------------------------
snap "$(iso $((NOW - 601)))" "$RED"
run MC_PROD_RED_MAX_AGE_S=600
[ "$(q '.projects["alpha-os"].prod.state')" = '"unknown"' ] && ok || bad "P5: a red record 601s old with max age 600 is unknown (got: $(q '.projects["alpha-os"].prod'))"
[ "$(q '.projects["alpha-os"].prod.generated_at')" = "\"$(iso $((NOW - 601)))\"" ] && ok || bad "P5: unknown carries generated_at (got: $(q '.projects["alpha-os"].prod'))"

# --- P6: no snapshot file; then a space in generated_at --------------------
rm -f "$SNAP"
run
[ "$(q '[.projects["alpha-os"].prod, .projects["beta-os"].prod]')" = '[{"state":"unknown","generated_at":"none"},{"state":"unknown","generated_at":"none"}]' ] \
  && ok || bad "P6: no snapshot is unknown for each vercel.conf project (got: $(q '.projects|map_values(.prod)'))"
[ "$(q '.projects["gamma-os"] | has("prod")')" = false ] && ok || bad "P6: a non-Vercel project stays without prod (got: $(q '.projects["gamma-os"].prod'))"
snap "$(date -u -d "@$((NOW - 60))" '+%Y-%m-%d %H:%M:%SZ')" "$RED"
run
[ "$(q '.projects["alpha-os"].prod.state')" = '"red"' ] && ok || bad "P6: a generated_at with a space parses as fresh (got: $(q '.projects["alpha-os"].prod'))"

# --- P7: no conductor fragment: the push is as before ----------------------
snap "$(iso $((NOW - 60)))" "$RED"
rm -f "$T/bin/merge-conductor.d/bh-8781-prod-red-hold.sh"
run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "P7: the push body is valid JSON"
[ "$(q '.projects | keys')" = '["alpha-os","beta-os","gamma-os"]' ] && ok || bad "P7: .projects keeps the 3 projects (got: $(q '.projects|keys'))"
[ "$(q '[.projects[] | has("prod")] | any')" = false ] && ok || bad "P7: no reader, no prod key (got: $(q '.projects|map_values(.prod)'))"
[ "$(wc -l < "$T/CURL.calls" 2>/dev/null)" = 1 ] && ok || bad "P7: the fake curl got exactly one push"

echo "fleet-status-push-prod-red.bh-8884-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
