#!/bin/bash
# tests/mc-failed-batch-stale.bh-9405-test.sh — BH-9405: the BH-8186 failed-batch
# hold parks a same-patch head with no solo proof after N conductor ticks
# (hold-stale). Unit suite over bin/lib/mc-failed-batch.sh only: no network,
# no git, no conductor.
#
#   S1-S3, S5-S7, S13-S14  fbh_decide: every row of the plan's decision table
#   S4     fbh_stale_ticks: unset = 6, `x` = 6, `0` = 0, `2` = 2
#   S8     fbh_held_bump counts one per tick
#   S9     the same tick id does not count twice
#   S10    another record (epoch, head) resets the count
#   S11    count 0 (a solo run pending) prints the stored count, writes nothing
#   S12    fbh_gc deletes an old .held file with its record, keeps a fresh one
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-failed-batch-stale.bh-9405-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$3', got '$2'"; fi; }
unset MC_FAILED_BATCH_STALE_TICKS MC_FAILED_BATCH_KEEP_DAYS MC_FAILED_BATCH_GC_INTERVAL_MIN P
# shellcheck source=bin/lib/mc-failed-batch.sh
. "$DIR/bin/lib/mc-failed-batch.sh" || { echo "FAIL: cannot source bin/lib/mc-failed-batch.sh"; exit 1; }
export MC_STATE_DIR="$T/state"; mkdir -p "$MC_STATE_DIR/failed-batch"
export MC_FAILED_BATCH_NOW=1792731960

# The decision table (plan, Failure modes). age 3600 is under the 86400 window; 90000 is past it.
eq "S1: no solo line, 6 of 6 held ticks -> hold-stale (THE REPRO)" "$(fbh_decide 1 - 3600 86400 6 6)" hold-stale
eq "S2: could-not-run, 7 of 6 -> hold-stale" "$(fbh_decide 1 could-not-run 3600 86400 7 6)" hold-stale
eq "S3: red (not reproduces), 6 of 6 -> hold-stale" "$(fbh_decide 1 red 3600 86400 6 6)" hold-stale
eq "S3b: 6 of 6 past the window -> hold-stale outranks clear:window" "$(fbh_decide 1 - 90000 86400 6 6)" hold-stale
eq "S5: 5 of 6 -> hold (one tick short)" "$(fbh_decide 1 - 3600 86400 5 6)" hold
eq "S6: solo pending, 99 of 6 -> hold (a proof is coming)" "$(fbh_decide 1 pending 3600 86400 99 6)" hold
eq "S7: knob 0, 99 held -> hold" "$(fbh_decide 1 - 3600 86400 99 0)" hold
eq "S7b: 5 of 6 past the window -> clear:window (as before)" "$(fbh_decide 1 - 90000 86400 5 6)" clear:window
eq "S7c: reproduces, 99 of 6 -> hold-judged (unchanged)" "$(fbh_decide 1 reproduces 3600 86400 99 6)" hold-judged
eq "S7d: clean, 99 of 6 -> clear:bystander" "$(fbh_decide 1 clean 3600 86400 99 6)" clear:bystander
eq "S7e: a new patch, 99 of 6 -> clear:new-patch" "$(fbh_decide 0 - 3600 86400 99 6)" clear:new-patch
eq "S7f: an unread compare, 99 of 6 -> wait" "$(fbh_decide '?' - 3600 86400 99 6)" wait
eq "S13: a non-integer held count -> hold" "$(fbh_decide 1 - 3600 86400 x 6)" hold
eq "S14: the 4-arg BH-8186 call -> hold" "$(fbh_decide 1 - 3600 86400)" hold

# S4 — the knob.
eq "S4: unset -> 6" "$(fbh_stale_ticks)" 6
eq "S4: x -> 6" "$(MC_FAILED_BATCH_STALE_TICKS=x fbh_stale_ticks)" 6
eq "S4: 0 -> 0" "$(MC_FAILED_BATCH_STALE_TICKS=0 fbh_stale_ticks)" 0
eq "S4: 2 -> 2" "$(MC_FAILED_BATCH_STALE_TICKS=2 fbh_stale_ticks)" 2
lane_knob() { [ "$2" = MC_FAILED_BATCH_STALE_TICKS ] && echo 9; }
eq "S4: the settings row (lane_knob) wins over the env" "$(MC_FAILED_BATCH_STALE_TICKS=2 fbh_stale_ticks)" 9
unset -f lane_knob

# S8-S11 — the held-tick counter.
F="$MC_STATE_DIR/failed-batch/example-org_x_9405"
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9405
eq "S8: held file path" "$(fbh_held_file "$F")" "$F.held"
eq "S8: first tick -> 1" "$(fbh_held_bump "$F" 100 "$HA" tickA 1)" 1
eq "S8: second tick -> 2" "$(fbh_held_bump "$F" 100 "$HA" tickB 1)" 2
eq "S9: the same tick again -> 2" "$(fbh_held_bump "$F" 100 "$HA" tickB 1)" 2
before=$(cat "$F.held")
eq "S11: pending (count 0) -> the stored count" "$(fbh_held_bump "$F" 100 "$HA" tickC 0)" 2
eq "S11: pending writes nothing" "$(cat "$F.held")" "$before"
eq "S10: another record (200, H) -> 1" "$(fbh_held_bump "$F" 200 "$HA" tickD 1)" 1
eq "S10: the file holds the new record" "$(cut -f1,3 "$F.held")" $'200\t1'
eq "S10b: no tick id counts by the epoch second" "$(fbh_held_bump "$F" 200 "$HA" '' 1)" 2

# S12 — retention: fbh_gc deletes an old .held file with its record.
OLD="$MC_STATE_DIR/failed-batch/example-org_x_1"
printf 'x\n' > "$OLD"; printf '1\th\t3\tt\n' > "$OLD.held"
touch -d '20 days ago' "$OLD" "$OLD.held"
rm -f "$MC_STATE_DIR/failed-batch/.gc"
fbh_gc >/dev/null
[ ! -e "$OLD.held" ] && pass "S12: an old .held file is deleted" || fail "S12: $OLD.held kept"
[ -e "$F.held" ] && pass "S12: a fresh .held file is kept" || fail "S12: $F.held deleted"

echo "mc-failed-batch-stale.bh-9405: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
