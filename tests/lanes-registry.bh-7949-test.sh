#!/bin/bash
# tests/lanes-registry.bh-7949-test.sh — BH-7934.2 (#7949): the onboard-run
# lane's registration. tests/lanes-registry-test.sh proves the registry rules
# for every lane; this pins what is particular to this one.
#
#   O1  cron/lanes/745-onboard-run.cron runs bin/onboard-run.sh every minute,
#       behind `hub-lease.sh check && flock -n` (the BH-1000 gate shape that
#       cron/lanes/731-d1-retention.cron already runs in prod), on the hub only
#   O2  catalog/lanes.d/onboard-run.json: hub scope, the same cadence, the
#       lane-off-onboard-run flag, wired, the log path, and every knob it
#       declares is read in bin/onboard-run.sh
#   O3  the rendered registry (bin/lanes-build.sh) carries the lane
#   O4  a host-name knob and the test seams are not settable
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry.bh-7949-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
CRON="$DIR/cron/lanes/745-onboard-run.cron"
LANE="$DIR/catalog/lanes.d/onboard-run.json"
SCRIPT="$DIR/bin/onboard-run.sh"
for f in "$CRON" "$LANE" "$SCRIPT"; do [ -f "$f" ] || { echo "FAIL setup: ${f#"$DIR"/} missing"; exit 1; }; done

echo "O1: the cron line"
mapfile -t LINES < <(grep -vE '^[[:space:]]*(#|$)' "$CRON")
[ "${#LINES[@]}" = 1 ] && ok "O1 one cron line" || bad "O1 ${#LINES[@]} cron lines"
[ "${LINES[0]:-}" = '* * * * * /root/harness/bin/hub-lease.sh check && flock -n /root/harness/locks/onboard-run.lock /root/harness/bin/onboard-run.sh >> /root/harness/logs/onboard-run-cron.log 2>&1' ] \
  && ok "O1 every minute, hub-lease.sh check && flock -n, then bin/onboard-run.sh" || bad "O1 line: ${LINES[0]:-}"
head -1 "$CRON" | grep -qx '# @hub-lanes' && ok "O1 a hub-lanes file" || bad "O1 header: $(head -1 "$CRON")"
grep -q 'hub-lease.sh check && /root/harness/bin/d1-retention.sh' "$DIR/cron/lanes/731-d1-retention.cron" \
  && ok "O1 the same hub-lease gate runs in prod in 731-d1-retention.cron" || bad "O1 731 no longer carries the gate"

echo "O2: the lane row"
J=$(jq -c . "$LANE") || { echo "FAIL O2 not JSON"; exit 1; }
[ "$(jq -r '[.id,.scope,.script,.cadence,(.boxes|join(",")),.switch.kind,.switch.name,(.wired|tostring),.stats.log]|join("|")' <<<"$J")" \
  = "onboard-run|hub|bin/onboard-run.sh|* * * * *|hub|flag|lane-off-onboard-run|true|logs/onboard-run.log" ] \
  && ok "O2 id, scope, script, cadence, boxes, switch, wired, log" || bad "O2 row: $J"
UNREAD=""
for k in $(jq -r '.knobs[].env' <<<"$J"); do
  grep -q "\${$k:-" "$SCRIPT" || UNREAD="$UNREAD $k"
  [ "$(jq -r --arg k "$k" '.knobs[]|select(.env==$k)|.read_in' <<<"$J")" = bin/onboard-run.sh ] || UNREAD="$UNREAD $k(read_in)"
done
[ -z "$UNREAD" ] && ok "O2 every knob is read in bin/onboard-run.sh" || bad "O2 knobs not read:$UNREAD"
[ "$(jq -r '[.knobs[]|select(.env=="ONBOARD_RUN_TRIES" or .env=="ONBOARD_RUN_STALE_MIN" or .env=="ONBOARD_RUN_EXCERPT_BYTES")|"\(.env)=\(.default)"]|join(" ")' <<<"$J")" \
  = "ONBOARD_RUN_TRIES=3 ONBOARD_RUN_STALE_MIN=30 ONBOARD_RUN_EXCERPT_BYTES=4096" ] \
  && ok "O2 the ticket's defaults: 3 tries, 30 minutes, 4096 bytes" || bad "O2 defaults: $(jq -c '[.knobs[]|{(.env):.default}]' <<<"$J")"
grep -q '^command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit onboard-run$' "$SCRIPT" \
  && grep -q '^command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply onboard-run$' "$SCRIPT" \
  && ok "O2 the script gates and applies its own lane id" || bad "O2 the script does not gate onboard-run"

echo "O3: the rendered registry"
OUT="$T/render"
mkdir -p "$OUT/catalog"
cp -r "$DIR/catalog/lanes.d" "$OUT/catalog/"
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$OUT" --write >/dev/null 2>&1; then
  [ "$(jq -r '.lanes[]|select(.id=="onboard-run")|.script' "$OUT/catalog/lanes.json")" = bin/onboard-run.sh ] \
    && ok "O3 lanes.json carries onboard-run" || bad "O3 onboard-run is not in the render"
else
  bad "O3 bin/lanes-build.sh --write failed"
fi

echo "O4: what a settings row may not drive"
[ "$(jq -r '[.knobs[]|select(.settable==false)|.env]|sort|join(" ")' <<<"$J")" = "ONBOARD_RUN_LIB_ONLY ONBOARD_RUN_NOW ONBOARD_SHARED_BOX ONBOARD_STATIONS_LIB" ] \
  && ok "O4 the host name and the two test seams are not settable" || bad "O4 settable:false = $(jq -c '[.knobs[]|select(.settable==false)|.env]' <<<"$J")"

echo "lanes-registry.bh-7949: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
