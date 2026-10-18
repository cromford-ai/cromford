#!/bin/bash
# tests/harness-sync-timer.bh-7191-test.sh — BH-7303 (BH-7191.1): the sync
# timer lane bin/harness-sync-timer.sh runs bin/harness-sync.sh deploy only when
# the last successful sync is older than HARNESS_SYNC_PERIOD_MIN.
#
# DRIVEN, NOT GREPPED: every case runs the shipped script in a scratch harness
# (its closure installed with scratch_install_closure) with a stub
# bin/harness-sync.sh that records its arguments and answers a set rc. The
# clock is pinned through HARNESS_SYNC_TIMER_NOW; the stamps get exact mtimes.
#   T1 last success 16 min old, period 15 -> one call, argument `deploy`
#   T2 14 min old -> no call; exactly 15 min -> one call
#   T3 HARNESS_SYNC_PERIOD_MIN=5 and a 6 min old success -> one call
#   T4 flags/lane-off-harness-sync-timer with the gate on -> no call
#   T5 locks/harness-sync.lock held -> no call, rc 0, under 5 s, attempt stamp untouched
#   T6 the stub fails rc 1 -> timer rc 1, last-success unchanged, one log line
#   T7 the next tick after T6 -> no call (one attempt per period)
#   T8 period `abc` -> 15; `2` -> 5; `999` -> 240
#   T9 missing stamp -> one call; a stamp in the future -> one call
#   T10 the timer's own lock held -> no call, rc 0
#   T11 the cron render puts the line on review2 and hub2
# Run from anywhere: tests/harness-sync-timer.bh-7191-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TIMER="$DIR/bin/harness-sync-timer.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1 (want '$3', got '$2')"; fi; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$TIMER" ] || { echo "FAIL: no $TIMER"; echo "harness-sync-timer.bh-7191-test: 0 pass, 1 fail"; exit 1; }

NOW=1760000000
HN=0
new_harness() { # -> H, a scratch harness with the timer's closure and a stub harness-sync
  HN=$((HN+1)); H="$T/h$HN"
  mkdir -p "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env"
  ( cd "$DIR" && scratch_install_closure bin/harness-sync-timer.sh "$H" >/dev/null ) || bad "closure install failed"
  cat > "$H/bin/harness-sync.sh" <<'SH'
#!/bin/bash
echo "$*" >> "${HARNESS:?}/calls"
exit "$(cat "$HARNESS/stub-rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$H/bin/harness-sync.sh"
  : > "$H/calls"
}
stamp() { # stamp <file> <age seconds>
  touch -d "@$((NOW - $2))" "$H/state/$1"
}
calls() { grep -c . "$H/calls"; }
tick() { # tick [VAR=val ...] -> runs the shipped lane once; RC holds its rc
  env HARNESS="$H" HARNESS_SYNC_TIMER_NOW="$NOW" LANE_GATE_DISABLE=1 "$@" "$TIMER" >/dev/null 2>&1
  RC=$?
}

# T1 / T2: the period boundary at the default 15 min.
new_harness; stamp harness-sync-last-success $((16*60)); tick
eq "T1 a 16 min old success runs one sync" "$(calls)" 1
eq "T1 the sync is called with deploy" "$(cat "$H/calls")" deploy
eq "T1 rc" "$RC" 0
[ -e "$H/state/harness-sync-timer-last-attempt" ] && ok || bad "T1 the attempt stamp is written"
new_harness; stamp harness-sync-last-success $((14*60)); tick
eq "T2 a 14 min old success runs nothing" "$(calls)" 0
eq "T2 rc" "$RC" 0
[ ! -e "$H/state/harness-sync-timer-last-attempt" ] && ok || bad "T2 a tick that is not due writes no attempt stamp"
new_harness; stamp harness-sync-last-success $((15*60)); tick
eq "T2 exactly 15 min is due" "$(calls)" 1

# T3: the settings row arrives as the env var lane_env_apply sets.
new_harness; stamp harness-sync-last-success $((6*60)); tick HARNESS_SYNC_PERIOD_MIN=5
eq "T3 period 5 and a 6 min old success runs one sync" "$(calls)" 1
new_harness; stamp harness-sync-last-success $((4*60)); tick HARNESS_SYNC_PERIOD_MIN=5
eq "T3 period 5 and a 4 min old success runs nothing" "$(calls)" 0

# T4: the lane switch, through the real lane gate.
new_harness; stamp harness-sync-last-success $((60*60)); : > "$H/flags/lane-off-harness-sync-timer"
tick LANE_GATE_DISABLE=0
eq "T4 lane-off-harness-sync-timer stops the sync" "$(calls)" 0
[ ! -e "$H/state/harness-sync-timer-last-attempt" ] && ok || bad "T4 lane off writes no attempt stamp"
rm -f "$H/flags/lane-off-harness-sync-timer"; tick LANE_GATE_DISABLE=0
eq "T4 with the gate on and no switch the sync runs" "$(calls)" 1

# T5: harness-sync's own lock held -> skip, never wait.
new_harness; stamp harness-sync-last-success $((60*60))
exec 7>"$H/locks/harness-sync.lock"; flock -n 7 || bad "T5 could not take the fixture lock"
S0=$(date +%s); tick; S1=$(date +%s)
exec 7>&-
eq "T5 a held harness-sync lock runs nothing" "$(calls)" 0
eq "T5 rc" "$RC" 0
[ $((S1 - S0)) -lt 5 ] && ok || bad "T5 the timer waited $((S1 - S0)) s on the lock"
[ ! -e "$H/state/harness-sync-timer-last-attempt" ] && ok || bad "T5 a skipped tick writes no attempt stamp"
grep -q 'skip: harness-sync running' "$H/logs/harness-sync-timer.log" 2>/dev/null && ok || bad "T5 one log line names the skip"
tick
eq "T5 the next tick with the lock free runs the sync" "$(calls)" 1

# T6 / T7: a failed sync is rc 1, leaves last-success alone, and backs off.
new_harness; stamp harness-sync-last-success $((60*60)); echo 1 > "$H/stub-rc"
M0=$(stat -c %Y "$H/state/harness-sync-last-success")
tick
eq "T6 the sync ran once" "$(calls)" 1
eq "T6 a failed sync exits 1" "$RC" 1
eq "T6 last-success is unchanged" "$(stat -c %Y "$H/state/harness-sync-last-success")" "$M0"
grep -q 'failed rc=1' "$H/logs/harness-sync-timer.log" 2>/dev/null && ok || bad "T6 the log names the failed rc"
NOW=$((NOW + 5*60)); tick
eq "T7 the next tick inside the period does not retry" "$(calls)" 1
NOW=$((NOW + 11*60)); tick
eq "T7 one period after the attempt it retries" "$(calls)" 2
NOW=1760000000

# A success: rc 0, a log line, and the timer itself never writes last-success.
new_harness; tick
eq "T6 a good sync is rc 0" "$RC" 0
[ ! -e "$H/state/harness-sync-last-success" ] && ok || bad "T6 the timer never writes last-success itself"
grep -q 'synced rc=0' "$H/logs/harness-sync-timer.log" 2>/dev/null && ok || bad "T6 the log says synced rc=0"

# T8: the period is clamped and a bad value is the default.
new_harness; stamp harness-sync-last-success $((14*60)); tick HARNESS_SYNC_PERIOD_MIN=abc
eq "T8 abc reads as 15 (14 min is not due)" "$(calls)" 0
stamp harness-sync-last-success $((16*60)); tick HARNESS_SYNC_PERIOD_MIN=abc
eq "T8 abc reads as 15 (16 min is due)" "$(calls)" 1
new_harness; stamp harness-sync-last-success $((4*60)); tick HARNESS_SYNC_PERIOD_MIN=2
eq "T8 2 reads as 5 (4 min is not due)" "$(calls)" 0
stamp harness-sync-last-success $((5*60)); tick HARNESS_SYNC_PERIOD_MIN=2
eq "T8 2 reads as 5 (5 min is due)" "$(calls)" 1
new_harness; stamp harness-sync-last-success $((239*60)); tick HARNESS_SYNC_PERIOD_MIN=999
eq "T8 999 reads as 240 (239 min is not due)" "$(calls)" 0
stamp harness-sync-last-success $((240*60)); tick HARNESS_SYNC_PERIOD_MIN=999
eq "T8 999 reads as 240 (240 min is due)" "$(calls)" 1

# T9: missing and future stamps are stale.
new_harness; tick
eq "T9 no last-success stamp runs one sync" "$(calls)" 1
new_harness; stamp harness-sync-last-success -3600; tick
eq "T9 a last-success in the future runs one sync" "$(calls)" 1

# T10: the timer's own lock dedupes two ticks.
new_harness; stamp harness-sync-last-success $((60*60))
exec 7>"$H/locks/harness-sync-timer.lock"; flock -n 7 || bad "T10 could not take the fixture lock"
tick
exec 7>&-
eq "T10 a held timer lock runs nothing" "$(calls)" 0
eq "T10 rc" "$RC" 0

# T11: the lane renders on the two boxes that have no project row.
for B in review2 hub2; do
  N=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" "$B" 2>/dev/null | grep -c '^\*/5 \* \* \* \* /root/harness/bin/harness-sync-timer.sh')
  eq "T11 render-cron.sh $B has one harness-sync-timer line" "$N" 1
done

echo "harness-sync-timer.bh-7191-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
