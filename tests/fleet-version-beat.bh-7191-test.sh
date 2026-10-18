#!/bin/bash
# tests/fleet-version-beat.bh-7191-test.sh — BH-7304 (BH-7191.2): the beat and
# nosync rules, bin/lib/fleet-version-rules.d/30-beat.sh and 40-nosync.sh, run
# through fvc_decide (bin/lib/fleet-version-decide.sh) on rows in the column
# order bin/fleet-version-check.sh writes:
#   box role sha reported_epoch lag last_beat_at sync_timer harness_synced_at
#
#   B1-B7  the beat rule (31/30/29 min, empty, garbage, future, threshold 60)
#   N1-N4  the nosync rule (0, empty, 1, other)
#   X1     lag 40 + beat 31 + timer 0: three ALERT lines, so neither rule stops
#   M1-M2  mutation: `>` -> `>=` in the beat rule; 0 -> OK in the nosync rule
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fleet-version-beat.bh-7191-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# shellcheck source=bin/lib/fleet-version-decide.sh
. "$REPO/bin/lib/fleet-version-decide.sh" || { echo "FAIL decide lib did not load"; exit 1; }
NOW=1792000000   # 2026-10-14T06:13:20Z
export FVC_NOW=$NOW
SHA=0123456789abcdef0123456789abcdef01234567
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# row <box> <beat> <timer> [lag] — a fresh report, lag 0 unless given.
row() { printf '%s\tbuild\t%s\t%s\t%s\t%s\t%s\t\n' "$1" "$SHA" "$((NOW - 60))" "${4:-0}" "$2" "$3"; }
dec() { fvc_decide; }
kind() { grep "^ALERT $1 $2 " || true; }

echo "B: beat"
eq "B1 beat 31 min old: one beat ALERT" "$(row b1 "$(iso $((NOW - 31*60)))" 1 | dec | kind b1 beat)" "ALERT b1 beat no heartbeat 31m"
eq "B2 beat 30 min old: no beat line" "$(row b2 "$(iso $((NOW - 30*60)))" 1 | dec | grep -c ' beat ')" 0
eq "B3 beat 29 min old: no beat line" "$(row b3 "$(iso $((NOW - 29*60)))" 1 | dec | grep -c ' beat ')" 0
eq "B4 no beat: on record" "$(row b4 "" 1 | dec | kind b4 beat)" "ALERT b4 beat no heartbeat on record"
eq "B5 garbage beat: on record" "$(row b5 garbage 1 | dec | kind b5 beat)" "ALERT b5 beat no heartbeat on record"
eq "B6 beat in the future: no beat line" "$(row b6 "$(iso $((NOW + 600)))" 1 | dec | grep -c ' beat ')" 0
eq "B7 FVC_MAX_BEAT_GAP_MIN=60: 31 min is no beat line" "$(row b7 "$(iso $((NOW - 31*60)))" 1 | FVC_MAX_BEAT_GAP_MIN=60 dec | grep -c ' beat ')" 0
eq "B7b FVC_MAX_BEAT_GAP_MIN=60: 61 min alerts" "$(row b7 "$(iso $((NOW - 61*60)))" 1 | FVC_MAX_BEAT_GAP_MIN=60 dec | kind b7 beat)" "ALERT b7 beat no heartbeat 61m"
eq "B8 a fresh box prints exactly the lag OK line" "$(row b8 "$(iso $((NOW - 60)))" 1 | dec)" "OK b8 lag=0m"

echo "N: nosync"
FRESH=$(iso $((NOW - 60)))
eq "N1 timer 0: one nosync ALERT naming the box" "$(row n1 "$FRESH" 0 | dec | kind n1 nosync)" "ALERT n1 nosync no sync timer"
OUT=$(row n2 "$FRESH" "" | dec)
eq "N2 timer empty: the not-reported OK line" "$(grep -c '^OK n2 sync timer not reported$' <<<"$OUT")" 1
eq "N2 timer empty: no ALERT" "$(grep -c '^ALERT' <<<"$OUT")" 0
eq "N3 timer 1: no nosync line" "$(row n3 "$FRESH" 1 | dec | grep -c 'sync timer')" 0
OUT=$(row n4 "$FRESH" yes | dec)
eq "N4 timer yes: not reported, no ALERT" "$(grep -c '^OK n4 sync timer not reported$' <<<"$OUT")/$(grep -c '^ALERT' <<<"$OUT")" "1/0"

echo "X: one box, every kind"
OUT=$(row x1 "$(iso $((NOW - 31*60)))" 0 40 | dec)
eq "X1 three ALERT lines" "$(grep -c '^ALERT x1 ' <<<"$OUT")" 3
eq "X1 kinds lag beat nosync, in rule order" "$(awk '$1 == "ALERT" { print $3 }' <<<"$OUT" | tr '\n' ' ')" "lag beat nosync "
OUT=$(printf '%s\n%s\n' "$(row y1 "" 0)" "$(row y2 "$FRESH" 1)" | dec)
eq "X2 two rows: only y1 alerts, twice" "$(awk '$1 == "ALERT" { print $2, $3 }' <<<"$OUT" | tr '\n' ';')" "y1 beat;y1 nosync;"

echo "M: mutation"
( cd "$REPO" && scratch_install_closure bin/fleet-version-check.sh "$T/mut" ) >/dev/null 2>&1 || bad "setup: could not install the mutation tree"
MUT="$T/mut/bin/lib/fleet-version-rules.d"
sed -i 's/age > max/age >= max/' "$MUT/30-beat.sh"
if grep -q 'age >= max' "$MUT/30-beat.sh"; then ok "M1 the mutation applied"; else bad "M1 the mutation did not apply"; fi
eq "M1 with >= the 30-min beat alerts" "$(row m1 "$(iso $((NOW - 30*60)))" 1 | FVC_RULES_DIR="$MUT" dec | grep -c ' beat ')" 1
sed -i 's/^    0) echo "ALERT/    00) echo "ALERT/' "$MUT/40-nosync.sh"
if grep -q '00) echo "ALERT' "$MUT/40-nosync.sh"; then ok "M2 the mutation applied"; else bad "M2 the mutation did not apply"; fi
eq "M2 with the 0 arm gone, timer 0 does not alert" "$(row m2 "$FRESH" 0 | FVC_RULES_DIR="$MUT" dec | grep -c nosync)" 0

echo
echo "fleet-version-beat.bh-7191: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
