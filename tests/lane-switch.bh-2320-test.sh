#!/bin/bash
# tests/lane-switch.bh-2320-test.sh — bin/lib/lane-switch.sh's lane_switch
# (BH-2320): a kill switch is a settings row, box row before fleet row, before
# it is a file.
#
# What is proved here:
#   A1 a fleet row `switch.x-off=1` turns the switch on with no file;
#   A2 the box row beats the fleet row;
#   A3 another box's row does not reach this box;
#   A4 THE TICKET'S DEFECT: a row saying 0 beats a file on the box (an ssh
#      touch), and says so in logs/lane-gate.log once per throttle window;
#   A5 the resolver never writes flags/;
#   A6 no row at all = the file decides, exactly as before (legacy parity),
#      and never through flag_active's reconcile (BH-2412: read-only);
#   A7 two switches and a knob in one tick cost ONE GET /api/settings;
#   A8 a box row key over 64 chars is skipped, logged, and the fleet row reads;
#   A9 an outage keeps the last cached row; values nobody can read (`2`,
#      `yes please`, `null`), a prefix-colliding key, a seeded row and a
#      .seen-* marker never turn a switch on;
#   P1-P3 the real bin/dora-digest.sh honours the row and ignores a
#      contradicting file, and still stops on the file when no row exists.
# Run from anywhere: tests/lane-switch.bh-2320-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/lane-switch.sh" "$T/h/bin/lib/" 2>/dev/null
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# The stub worker, at the path _lg_ensure_client sources. $ROWS_FILE is the
# settings table the GET returns; every request is appended to $CALLS so "one
# fetch per tick" is counted, not assumed. flag_active exists only when
# STUB_FLAG_ACTIVE=1, so both halves of the legacy step are reachable. It is
# written once and installed into each scratch harness.
cat > "$T/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_FLAG_ACTIVE:-}" = 1 ]; then
  flag_active() { echo "FLAG_ACTIVE $1" >> "$CALLS"; [ -f "$HARNESS/flags/$1" ]; }
fi
SH
cp "$T/stub-jobs-client.sh" "$T/h/bin/jobs-client.sh"

# rows k=v [k=v...] — the settings table. `seed:k=v` is a row the registry
# seed owns, which the cache keeps apart and which must answer nothing.
rows() {
  local out='[]' kv k v actor
  for kv in "$@"; do
    actor=api
    case "$kv" in seed:*) actor=registry-seed; kv="${kv#seed:}" ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" --arg a "$actor" '. + [{key:$k,value:$v,actor:$a}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/calls" "$T/rows.json"
  : > "$T/calls"; UNREACHABLE=""; AT="$NOW"; BOX=hub-1; STUB_FLAG_ACTIVE=""
}

# ask <name> — one read in a cold child shell; prints `rc=<n> src=<where>`.
ask() {
  env HARNESS="$T/h" LANE_GATE_NOW="$AT" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      UNREACHABLE="$UNREACHABLE" JOBS_BOX="$BOX" STUB_FLAG_ACTIVE="$STUB_FLAG_ACTIVE" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
        lane_switch "$1"; rc=$?
        echo "rc=$rc src=${LANE_SWITCH_SRC:-unset}"' _ "$1" 2>/dev/null
}
loglines() { [ -f "$T/h/logs/lane-gate.log" ] && grep -c "$1" "$T/h/logs/lane-gate.log" || echo 0; }

# A1 — fleet row on, no file.
reset; rows switch.x-off=1
eq "A1 fleet row 1" "$(ask x-off)" "rc=0 src=fleet-row"

# A2 — box row 0 beats fleet row 1. JOBS_BOX is upper case on purpose: the
# worker only takes lower-case keys, so the box half is lowered.
reset; BOX=Hub-1; rows switch.x-off.hub-1=0 switch.x-off=1
eq "A2 box row beats fleet row" "$(ask x-off)" "rc=1 src=box-row"
reset; rows switch.x-off.hub-1=1
eq "A2b box row alone" "$(ask x-off)" "rc=0 src=box-row"

# A3 — another box's row, nothing else.
reset; rows switch.x-off.otherbox=1
eq "A3 other box's row" "$(ask x-off)" "rc=1 src=legacy-file"

# A4 — row 0 + an ssh-touched file: the row wins and the file is named, once.
reset; rows switch.x-off=0; touch "$T/h/flags/x-off"
eq "A4 row 0 beats the file" "$(ask x-off)" "rc=1 src=fleet-row"
eq "A4 one line names the ignored file" "$(loglines 'switch x-off: row says 0 (switch.x-off), flags/x-off ignored')" "1"
AT=$((NOW+60)); ask x-off >/dev/null
eq "A4 a second read inside the throttle adds no line" "$(loglines 'flags/x-off ignored')" "1"
[ -f "$T/h/flags/x-off" ] && ok || bad "A4 the resolver must not delete the file"

# A5 — row 1, no file: on, and nothing is written to flags/.
reset; rows switch.x-off=1
eq "A5 row 1" "$(ask x-off)" "rc=0 src=fleet-row"
eq "A5 flags/ untouched" "$(ls -A "$T/h/flags" | wc -l | tr -d ' ')" "0"

# A6 — no rows: the file decides, both ways, with and without flag_active.
reset; rows; touch "$T/h/flags/x-off"
eq "A6 no row, file" "$(ask x-off)" "rc=0 src=legacy-file"
rm -f "$T/h/flags/x-off"; AT=$((NOW+1))
eq "A6 no row, no file" "$(ask x-off)" "rc=1 src=legacy-file"
reset; rows; STUB_FLAG_ACTIVE=1; touch "$T/h/flags/x-off"
eq "A6 no row, flag_active loaded" "$(ask x-off)" "rc=0 src=legacy-file"
eq "A6 flag_active is not asked (it writes flags/)" "$(grep -c '^FLAG_ACTIVE x-off$' "$T/calls")" "0"
reset; rows switch.x-off=1; STUB_FLAG_ACTIVE=1
ask x-off >/dev/null
eq "A6 a row answers without flag_active" "$(grep -c '^FLAG_ACTIVE' "$T/calls")" "0"

# A7 — one tick, two switches and a knob: one settings GET.
reset; rows switch.x-off=1 switch.y-off=0
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" JOBS_BOX=hub-1 \
  bash -c '
    . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
    lane_switch x-off; lane_switch y-off
    lane_knob alert-triage TRIAGE_MAX_FAMILIES >/dev/null' >/dev/null 2>&1
eq "A7 one GET /api/settings" "$(grep -c '^GET /api/settings$' "$T/calls")" "1"

# A8 — a box name that makes the key longer than 64: fleet row still reads.
reset; BOX=$(printf 'b%.0s' $(seq 1 60)); rows switch.x-off=1
eq "A8 fleet row reads past an unbuildable box key" "$(ask x-off)" "rc=0 src=fleet-row"
eq "A8 the skip is logged" "$(loglines 'switch x-off: box row for')" "1"

# A9 — outage keeps the cached row; unreadable rows are no rows.
reset; rows switch.x-off=1
ask x-off >/dev/null
AT=$((NOW+3600)); UNREACHABLE=1; rm -f "$T/rows.json"
eq "A9 cached row survives an outage" "$(ask x-off)" "rc=0 src=fleet-row"
for v in 2 "yes please" null; do
  reset; rows "switch.x-off=$v"
  eq "A9 value '$v' is no row" "$(ask x-off)" "rc=1 src=legacy-file"
done
eq "A9 the unreadable value is logged" "$(loglines "row switch.x-off='null' is not")" "1"
reset; rows "switch.x-off=yes please"; touch "$T/h/flags/x-off"
eq "A9 unreadable row falls to the file" "$(ask x-off)" "rc=0 src=legacy-file"
reset; rows switch.x-off-extra=1 switch.x-off.hub-1.extra=1
eq "A9 prefix-colliding keys" "$(ask x-off)" "rc=1 src=legacy-file"
reset; rows seed:switch.x-off=1
eq "A9 a registry-seed row answers nothing" "$(ask x-off)" "rc=1 src=legacy-file"
reset; rows; mkdir -p "$T/h/state/lane-gate"; touch "$T/h/state/lane-gate/.seen-x-off"
eq "A9 a .seen marker is not a switch" "$(ask x-off)" "rc=1 src=legacy-file"
reset; rows switch.x-off=1
eq "A9 LANE_GATE_DISABLE=1 skips the row and reads the file (BH-2407)" \
  "$(env LANE_GATE_DISABLE=1 HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      bash -c '. "$HARNESS/bin/lib/lane-switch.sh"; lane_switch x-off; echo "rc=$? src=$LANE_SWITCH_SRC"' 2>/dev/null)" "rc=1 src=legacy-file"
reset; rows 'switch.x.off=1'
eq "A9 a dotted name is refused" "$(ask x.off)" "rc=1 src=none"

# P1-P3 — the real bin/dora-digest.sh, run as the existing digest suite runs it
# (HARNESS pointed at a scratch tree). The json it writes for today is the proof
# it got past the switch.
D="$T/d"; mkdir -p "$D/bin" "$D/flags" "$D/logs" "$D/state"
cp "$T/stub-jobs-client.sh" "$D/bin/jobs-client.sh"
: > "$D/fleet.conf"
TODAY=$(date -u +%F)
digest() {
  scratch_rm "$D/state/dora"; scratch_rm "$D/state/settings-cache.json"; scratch_rm "$D/state/lane-gate"
  env HARNESS="$D" FLEET_CONF="$D/fleet.conf" CALLS="$T/calls" ROWS_FILE="$T/rows.json" JOBS_BOX=hub-1 \
    "$DIR/bin/dora-digest.sh" --window 24h --no-send >/dev/null 2>&1
}
rm -f "$D/flags/dora-digest-off"; rows switch.dora-digest-off=1
digest; RC=$?
eq "P1 row 1, no file: exits 0" "$RC" "0"
[ ! -e "$D/state/dora/$TODAY.json" ] && ok || bad "P1 row switch.dora-digest-off=1 must stop the digest before any work"
touch "$D/flags/dora-digest-off"; rows switch.dora-digest-off=0
digest; RC=$?
eq "P2 row 0 + file: exits 0" "$RC" "0"
[ -s "$D/state/dora/$TODAY.json" ] && ok || bad "P2 row 0 must beat flags/dora-digest-off (the digest did not run)"
grep -q 'flags/dora-digest-off ignored' "$D/logs/lane-gate.log" 2>/dev/null && ok || bad "P2 the ignored file must be logged"
rows
digest
[ ! -e "$D/state/dora/$TODAY.json" ] && ok || bad "P3 with no row, flags/dora-digest-off must still stop the digest"

echo "lane-switch.bh-2320: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
