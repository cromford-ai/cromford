#!/bin/bash
# tests/watchdog-ping-registry.bh-7191-test.sh — BH-7303 (BH-7191.1): the
# watchdog's ping set comes from the registry's box roles.
#
#   W1 `bin/registry-seed.sh --emit` with an `@boxrole ... review` line gives
#      lane_boxes {watchdog-ping, review2} and {harness-sync-timer, review2}
#   W2 a gate-only `@boxrole` box gives no row for either lane
#   W3 a `@retired`-only box gives no row; the other lanes keep their
#      lane-registry rows
#   W4 `bin/fleet-status-push.sh` against a scratch harness: the POSTed
#      snapshot's expected_boxes has review-2 and not the gate-only box; with
#      no readable role list the field is absent (the watchdog falls back)
#   W5 the committed fleet.conf's expected set holds every name in
#      worker/watchdog/src/boxes.json (the switch drops no box that pages today)
#   W6 a snapshot over the 60000-byte cap is shed and still carries
#      expected_boxes
#   W7 `bin/render-cron.sh review2` / `hub2` ping under the `@boxrole` box name
# Run from anywhere: tests/watchdog-ping-registry.bh-7191-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SEED="$DIR/bin/registry-seed.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1 (want '$3', got '$2')"; fi; }
unset HUB_BOX_NAME LANE_REGISTRY
export REGISTRY_SOURCE=file

# ---- W1-W3 the seed's lane rows ------------------------------------------------------------
TREE="$T/tree"; mkdir -p "$TREE/catalog"
cat > "$TREE/fleet.conf" <<'EOF'
# fixture registry
# @boxrole box-review-2 review2 review
# @boxrole box-gate-1 gate1 gate-only
# @retired gone-os box-gone
alpha-os Org/alpha https://a.example /api/board 2 box-alpha 192.0.2.1
EOF
printf '{"box_aliases":{"box-hub":"hub"},"accounts":{}}\n' > "$TREE/catalog/cost-accounts.json"
cat > "$T/lanes.json" <<'EOF'
{"lanes":[{"id":"watchdog-ping","boxes":["alpha","gate1","gone"]},{"id":"harness-sync-timer","boxes":["gate1"]},{"id":"other","boxes":["gate1","gone"]}]}
EOF
env LANE_REGISTRY="$T/lanes.json" "$SEED" --emit --root "$TREE" > "$T/seed.json" 2>"$T/seed.err"; R=$?
eq "W1 --emit rc ($(head -c 200 "$T/seed.err"))" "$R" 0
rows() { jq -r --arg l "$1" '[.lane_boxes[] | select(.lane == $l) | .box_id] | join(",")' "$T/seed.json"; }
eq "W1 watchdog-ping rows come from the roles" "$(rows watchdog-ping)" "alpha,hub,review2"
eq "W1 harness-sync-timer rows come from the roles" "$(rows harness-sync-timer)" "alpha,hub,review2"
eq "W3 another lane keeps its lane-registry rows" "$(rows other)" "gate1,gone"
eq "W2 no gate-only row in either lane" "$(jq '[.lane_boxes[] | select(.box_id == "gate1" and (.lane == "watchdog-ping" or .lane == "harness-sync-timer"))] | length' "$T/seed.json")" 0
eq "W3 no retired row in either lane" "$(jq '[.lane_boxes[] | select(.box_id == "gone" and (.lane == "watchdog-ping" or .lane == "harness-sync-timer"))] | length' "$T/seed.json")" 0
eq "W1 the rows stay sorted and unique" "$(jq -c '.lane_boxes == (.lane_boxes | unique | sort_by(.lane, .box_id))' "$T/seed.json")" true
# A role list that cannot be built refuses the seed (rc 2, no payload).
printf 'bad row\n' >> "$TREE/fleet.conf"
env LANE_REGISTRY="$T/lanes.json" "$SEED" --emit --root "$TREE" > "$T/seed-bad.json" 2>/dev/null; R=$?
eq "W1 a refused fleet.conf is rc 2" "$R" 2
[ ! -s "$T/seed-bad.json" ] && ok || bad "W1 a refused seed prints no payload"

# ---- W4 / W6 the snapshot field ------------------------------------------------------------
H="$T/h"; mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/fakebin" "$H/locks"
for S in bin/fleet-status-push.sh bin/fleet-conf.sh bin/box-for.sh bin/fleet-fly-block.sh; do
  ( cd "$DIR" && scratch_install_closure "$S" "$H" >/dev/null ) || bad "W4 closure install of $S failed"
done
printf 'HARNESS_SECRET=fsp-fixture\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\ncase "$*" in *watchdog.invalid*) cat > "%s/PUSH.json" ;; *) cat >/dev/null ;; esac\n' "$T" > "$H/fakebin/curl"
chmod +x "$H/fakebin/curl"
cat > "$H/fleet.conf" <<'EOF'
# fixture registry
# @boxrole box-review-2 review2 review
# @boxrole box-gate-1 gate1 gate-only
# @retired gone-os box-gone
alpha-os Org/alpha https://a.example /api/board 2 box-alpha 192.0.2.1
EOF
push() { rm -f "$T/PUSH.json"; env PATH="$H/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 \
  bash "$H/bin/fleet-status-push.sh" >/dev/null 2>"$T/fsp.err"; }
push
[ -s "$T/PUSH.json" ] && ok || bad "W4 nothing was pushed ($(head -c 300 "$T/fsp.err"))"
eq "W4 expected_boxes is the non-gate-only, non-retired set" \
  "$(jq -c '.expected_boxes' "$T/PUSH.json" 2>/dev/null)" '["box-hub","box-alpha","box-review-2"]'
# No role list (fleet-conf.sh cannot load its lib) -> no field, the watchdog keeps boxes.json.
mv "$H/bin/lib/cron-lines.sh" "$H/bin/lib/cron-lines.sh.off"
push
eq "W4 no role list: the snapshot has no expected_boxes" "$(jq -r 'has("expected_boxes")' "$T/PUSH.json" 2>/dev/null)" false
eq "W4 no role list: the snapshot still pushes the projects" "$(jq -r '.projects | keys | join(",")' "$T/PUSH.json" 2>/dev/null)" alpha-os
mv "$H/bin/lib/cron-lines.sh.off" "$H/bin/lib/cron-lines.sh"

# W6: 300 rows with long names push a snapshot over the cap.
{ cat "$H/fleet.conf"
  for i in $(seq 1 300); do
    printf 'pad-%03d-%s Org/pad-%03d https://pad.example /api/board 3 box-alpha 192.0.2.1\n' "$i" "$(printf 'x%.0s' $(seq 1 120))" "$i"
  done; } > "$H/fleet.big"
cp "$H/fleet.conf" "$H/fleet.small"; cp "$H/fleet.big" "$H/fleet.conf"
push
cp "$H/fleet.small" "$H/fleet.conf"
eq "W6 the snapshot was shed for size" "$(jq -r '.snapshot_trimmed' "$T/PUSH.json" 2>/dev/null)" size
eq "W6 the shed snapshot keeps expected_boxes" "$(jq -c '.expected_boxes' "$T/PUSH.json" 2>/dev/null)" '["box-hub","box-alpha","box-review-2"]'

# ---- W5 the committed fleet.conf covers boxes.json -----------------------------------------
EXP=$(env FLEET_CONF="$DIR/fleet.conf" "$DIR/bin/fleet-conf.sh" --boxes-with-roles \
  | awk -F'\t' '$3 != "gate-only" && $3 != "retired" {print $1}')
MISS=""
for B in $(jq -r '.[]' "$DIR/worker/watchdog/src/boxes.json"); do
  grep -qxF -- "$B" <<<"$EXP" || MISS="$MISS $B"
done
eq "W5 every boxes.json name is in the derived set" "$MISS" ""
grep -qxF box-review-2 <<<"$EXP" && ok || bad "W5 review-2 is in the derived set"
grep -qxF bh-hub-2 <<<"$EXP" && ok || bad "W5 bh-hub-2 is in the derived set"

# ---- W7 the committed lane: review2 and hub2 ping under their @boxrole names -------------
for P in review2:box-review-2 hub2:bh-hub-2; do
  N=$(env -u FLEET_CONF HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" "${P%%:*}" 2>/dev/null \
    | grep -cxF "*/5 * * * * /root/harness/bin/watchdog-ping.sh ${P#*:}")
  eq "W7 render-cron.sh ${P%%:*} pings as ${P#*:}" "$N" 1
done

echo "watchdog-ping-registry.bh-7191-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
