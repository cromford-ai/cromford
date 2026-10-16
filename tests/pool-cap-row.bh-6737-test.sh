#!/bin/bash
# tests/pool-cap-row.bh-6737-test.sh — BH-6737: bin/pool-cap.sh reads the
# POOL_CAP settings row lane.fly-pool.<project>.pool_cap.
#
# Ladder: flag-file digits > settings row (POOL_AUTOSCALE on only) >
# fly/pool-caps.conf > 0, then POOL_CAP_MAX trims. bin/jobs-client.sh is a stub
# over a file store ($T/store/kv/<key>), so no worker is reached.
#
# K1 --knob-key, R1 no row, R2 row beats conf, R3 flag beats row, R4 row 0,
# R5 kill flag ignores the row, R6 outage reads the cache, R7 non-digit row,
# R8 no jobs-client.sh (the pre-BH-6737 answer).
# Run from anywhere: tests/pool-cap-row.bh-6737-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; S="$T/store"
mkdir -p "$H/flags" "$H/env" "$H/logs" "$H/state" "$H/fly" "$S/kv"
scratch_install_closure bin/pool-cap.sh "$H" >/dev/null || bad "install bin/pool-cap.sh"
# The stub replaces the real client the closure copied. Knobs are files in $S
# so no env var leaks between cases: $S/outage (rc 1 on get), $S/set_rc.
cat > "$H/bin/jobs-client.sh" <<STUB
#!/bin/bash
S="$S"
echo "\$*" >> "\$S/calls"
case "\${1:-}" in
  setting-get) [ -e "\$S/outage" ] && exit 1
               [ -f "\$S/kv/\$2" ] || { echo; exit 2; }
               cat "\$S/kv/\$2"; echo; exit 0 ;;
  setting-set) rc=\$(cat "\$S/set_rc" 2>/dev/null || echo 0)
               [ "\$rc" = 0 ] || exit "\$rc"
               printf '%s' "\$3" > "\$S/kv/\$2"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/jobs-client.sh"
K=lane.fly-pool.pa.pool_cap

# cap <project> [VAR=value ...] — what bin/pool-cap.sh prints
cap() { local p="$1"; shift; env -u POOL_CAP_MAX -u POOL_AUTOSCALE HARNESS="$H" "$@" bash "$H/bin/pool-cap.sh" "$p" 2>/dev/null; }
reset() { rm -f "$S/kv/"* "$S/calls" "$S/outage" "$H/state/settings-cache.json" "$H/fly/pool-caps.conf"; : > "$H/flags/fly-pool-pa"; }

echo "--- K1: --knob-key"
o=$(HARNESS="$H" bash "$H/bin/pool-cap.sh" --knob-key Cromford 2>/dev/null); rc=$?
{ [ "$rc" = 0 ] && [ "$o" = lane.fly-pool.cromford.pool_cap ]; } && ok || bad "K1 key '$o' rc $rc"
long=$(printf 'p%.0s' $(seq 1 60))
o=$(HARNESS="$H" bash "$H/bin/pool-cap.sh" --knob-key "$long" 2>/dev/null); rc=$?
{ [ "$rc" = 2 ] && [ -z "$o" ]; } && ok || bad "K1 60-char project rc $rc out '$o'"
for p in 'a/b' '../pa' ''; do
  o=$(HARNESS="$H" bash "$H/bin/pool-cap.sh" --knob-key "$p" 2>/dev/null); rc=$?
  { [ "$rc" = 2 ] && [ -z "$o" ]; } && ok || bad "K1 project '$p' rc $rc out '$o'"
done
# the same key as the lane gate's _lg_setting_key (the console's settingKey form)
if [ -r "$(dirname "$0")/../bin/lib/lane-gate.sh" ]; then
  lg=$(grep -A7 '^_lg_setting_key()' "$(dirname "$0")/../bin/lib/lane-gate.sh" | grep -c 'kpfx).$id.$p.$env')
  [ "$lg" = 1 ] && ok || bad "K1 _lg_setting_key no longer builds lane.<id>.<project>.<env>"
fi

echo "--- R1: no row, conf pa 5 -> 5"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"
[ "$(cap pa)" = 5 ] && ok || bad "R1 got '$(cap pa)'"

echo "--- R2: row 3 beats conf 5"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"; printf 3 > "$S/kv/$K"
[ "$(cap pa)" = 3 ] && ok || bad "R2 got '$(cap pa)'"
grep -q "setting-get $K" "$S/calls" 2>/dev/null && ok || bad "R2 no setting-get call for $K"

echo "--- R3: flag 2 beats row 3, and the row is not read"
reset; printf 3 > "$S/kv/$K"; printf '2\n' > "$H/flags/fly-pool-pa"
[ "$(cap pa)" = 2 ] && ok || bad "R3 got '$(cap pa)'"
[ ! -s "$S/calls" ] && ok || bad "R3 the row was read: $(cat "$S/calls")"

echo "--- R4: row 0 beats conf 5; POOL_CAP_MAX trims it"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"; printf 0 > "$S/kv/$K"
[ "$(cap pa)" = 0 ] && ok || bad "R4 got '$(cap pa)'"
[ "$(cap pa POOL_CAP_MAX=4)" = 4 ] && ok || bad "R4 MAX 4 got '$(cap pa POOL_CAP_MAX=4)'"

echo "--- R5: POOL_AUTOSCALE=0 ignores the row"
reset; printf 'pa 6\n' > "$H/fly/pool-caps.conf"; printf 3 > "$S/kv/$K"
[ "$(cap pa POOL_AUTOSCALE=0)" = 6 ] && ok || bad "R5 got '$(cap pa POOL_AUTOSCALE=0)'"
rm -f "$H/fly/pool-caps.conf"
[ "$(cap pa POOL_AUTOSCALE=0)" = 3 ] && ok || bad "R5 no conf got '$(cap pa POOL_AUTOSCALE=0)' (want the old default 3)"
[ ! -s "$S/calls" ] && ok || bad "R5 the row was read under the kill flag"

echo "--- R6: outage reads the cache, whatever its age"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"; touch "$S/outage"
jq -nc --arg k "$K" '{fetched_at:0, values:{($k):"3"}}' > "$H/state/settings-cache.json"
[ "$(cap pa)" = 3 ] && ok || bad "R6 cached got '$(cap pa)'"
rm -f "$H/state/settings-cache.json"
[ "$(cap pa)" = 5 ] && ok || bad "R6 no cache got '$(cap pa)' (want conf 5)"

echo "--- R7: a row with no digits is ignored"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"; printf abc > "$S/kv/$K"
[ "$(cap pa)" = 5 ] && ok || bad "R7 got '$(cap pa)'"

echo "--- R8: no bin/jobs-client.sh -> the old answer"
reset; printf 'pa 5\n' > "$H/fly/pool-caps.conf"; printf 3 > "$S/kv/$K"
mv "$H/bin/jobs-client.sh" "$T/jc.off"
[ "$(cap pa)" = 5 ] && ok || bad "R8 got '$(cap pa)'"
rm -f "$H/fly/pool-caps.conf"
[ "$(cap pa)" = 0 ] && ok || bad "R8 nothing configured got '$(cap pa)'"
mv "$T/jc.off" "$H/bin/jobs-client.sh"

echo "pool-cap-row: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
