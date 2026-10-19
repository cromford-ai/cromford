#!/bin/bash
# tests/merge-conductor-ready-first-test.sh — BH-7376 item 3: the full tick
# gives READY rows the first claim on its worker window, after the hotfix rows
# and before WAIT_CI and HEAD_MOVED rows, so a merge never waits behind
# re-reads.
#
# THE INCIDENT (hub, 2026-10-17/18). The full tick's window
# (MC_FULL_TICK_BUDGET_S, 1500 s) ran out before it reached the READY rows:
# 137 to 151 `WINDOW_DEFERRED: under 15s of worker time left` lines an hour,
# and cromford #7361 sat in READY for 316 min.
#
# The REAL mc_ready_first (bin/lib/mc/tick-scope.sh) orders 120 open-list rows
# against a pr-state.tsv; a window that fits 10 workers then starts them in
# that order, the way the worker loop in bin/merge-conductor.sh walks ROWS.
#   R1  with 120 rows and a window of 10, the 10 rows started are the 10 READY
#       rows, and no WAIT_CI or HEAD_MOVED row starts before a READY row
#   R2  inside each group the list order is kept (stable)
#   R3  a row with no pr-state line (a new PR) goes with the non-READY rows
#   R4  another repo's READY row with the same number does not count
#   R5  no pr-state file: the order is unchanged
#   R6  the conductor calls mc_ready_first after the hotfix split and before
#       the first worker starts
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-ready-first-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mc_log() { printf '%s\n' "$*" >> "$T/log"; }
# shellcheck source=bin/lib/mc/tick-scope.sh
. "$DIR/bin/lib/mc/tick-scope.sh"
declare -F mc_ready_first >/dev/null || { echo "FAIL: mc_ready_first is not defined in bin/lib/mc/tick-scope.sh"; echo "merge-conductor-ready-first: 0 passed, 1 failed"; exit 1; }

SLUG=example-org/demo
ROWSF="$T/pr-state.tsv"; : > "$ROWSF"
ROWS=()
# 120 rows. READY rows are numbers divisible by 12 (10 of them), and they sit
# at the END of the list, so a list-order tick reaches them last.
for i in $(seq 1 120); do
  st=WAIT_CI; [ $((i % 3)) = 0 ] && st=HEAD_MOVED; [ $((i % 12)) = 0 ] && st=READY
  [ "$i" = 7 ] || printf '%s#%s\t%s\t0\th\th\t-\t-\tu\n' "$SLUG" "$i" "$st" >> "$ROWSF"
done
printf 'example-org/other#5\tREADY\t0\th\th\t-\t-\tu\n' >> "$ROWSF"
for i in $(seq 120 -1 1); do ROWS+=("$i"$'\t'"https://github.com/$SLUG/pull/$i"$'\tsha\tbr'); done
MC_ROWS="$ROWSF"
mapfile -t ORDERED < <(mc_ready_first "$SLUG" "${ROWS[@]}")

# The worker loop: a window that fits 10 starts the first 10 rows in order.
STARTED=(); for r in "${ORDERED[@]}"; do [ "${#STARTED[@]}" -lt 10 ] || break; STARTED+=("${r%%$'\t'*}"); done
state_of() { awk -F'\t' -v k="$SLUG#$1" '$1==k {print $2; exit}' "$ROWSF"; }

# --- R1 ---------------------------------------------------------------------
[ "${#ORDERED[@]}" = 120 ] && ok || bad "R1 every row is kept (got ${#ORDERED[@]} of 120)"
NR=0; for n in "${STARTED[@]}"; do [ "$(state_of "$n")" = READY ] && NR=$((NR + 1)); done
[ "$NR" = 10 ] && ok || bad "R1 the 10 rows the window starts are the 10 READY rows (READY started: $NR; started: ${STARTED[*]})"
SEEN_OTHER=0; LATE=""
for r in "${ORDERED[@]}"; do
  n="${r%%$'\t'*}"; s=$(state_of "$n")
  if [ "$s" = READY ]; then [ "$SEEN_OTHER" = 1 ] && LATE="$LATE $n"; else SEEN_OTHER=1; fi
done
[ -z "$LATE" ] && ok || bad "R1 a READY row came after a WAIT_CI/HEAD_MOVED row:$LATE"

# --- R2 ---------------------------------------------------------------------
[ "${STARTED[*]}" = "120 108 96 84 72 60 48 36 24 12" ] && ok || bad "R2 READY rows keep their list order (got ${STARTED[*]})"
REST=$(printf '%s\n' "${ORDERED[@]:10}" | cut -f1 | tr '\n' ' ')
WANT=$(for i in $(seq 120 -1 1); do [ $((i % 12)) = 0 ] || printf '%s ' "$i"; done)
[ "$REST" = "$WANT" ] && ok || bad "R2 the other rows keep their list order"

# --- R3/R4 ------------------------------------------------------------------
printf '%s\n' "${ORDERED[@]:10}" | cut -f1 | grep -qx 7 && ok || bad "R3 a row with no pr-state line stays among the non-READY rows"
TOP10=" $(printf '%s\n' "${ORDERED[@]:0:10}" | cut -f1 | tr '\n' ' ')"
case "$TOP10" in
  *" 5 "*) bad "R4 another repo's READY #5 must not lift $SLUG#5" ;;
  *) ok ;;
esac

# --- R5 ---------------------------------------------------------------------
MC_ROWS="$T/none.tsv"
mapfile -t SAME < <(mc_ready_first "$SLUG" "${ROWS[@]}")
[ "$(printf '%s\n' "${SAME[@]}")" = "$(printf '%s\n' "${ROWS[@]}")" ] && ok || bad "R5 no pr-state file: the order is unchanged"

# --- R6 ---------------------------------------------------------------------
C="$DIR/bin/merge-conductor.sh"
L_HOT=$(grep -n "heads this tick's order" "$C" | head -1 | cut -d: -f1)
L_RF=$(grep -n 'mc_ready_first "\$SLUG"' "$C" | head -1 | cut -d: -f1)
L_LOOP=$(grep -n '^  # ---- one worker per PR' "$C" | head -1 | cut -d: -f1)
[ -n "$L_RF" ] && [ -n "$L_HOT" ] && [ -n "$L_LOOP" ] && [ "$L_HOT" -lt "$L_RF" ] && [ "$L_RF" -lt "$L_LOOP" ] \
  && ok || bad "R6 bin/merge-conductor.sh calls mc_ready_first after the hotfix split and before the worker loop (lines: hot=${L_HOT:-?} rf=${L_RF:-none} loop=${L_LOOP:-?})"

echo "merge-conductor-ready-first: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
