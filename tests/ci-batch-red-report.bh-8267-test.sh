#!/bin/bash
# tests/ci-batch-red-report.bh-8267-test.sh — bin/ci-batch-red-report.sh prints
# the red-batch rate over its window as the first stdout line (BH-8267). The
# merge queue's default batch_size stays 3 until that rate is under 15 percent
# for a week; this line is where a person reads the rate.
#
# Seam shape as bh-8048: stub lane-gate, gh-budget and gh-repo-token libs; the
# REAL bin/lib/gh-ci-read.sh; a fake `gh` on PATH that serves an empty run list
# for harness-ci.yml, appends each argv to calls.txt, and exits 1 on any other
# path (0 network calls). Each case seeds its own run records with unique ids
# and injects NOW, so no case depends on another.
#
# WHAT IT PINS (plan "Acceptance tests"):
#   R1  4 red of 10, --dry-run: line 1 is the rate line, line 2 the TSV columns;
#       a normal run prints the same line, latest.tsv and red_rate= unchanged
#   R2  3 of 20 = 15 percent (the boundary)
#   R3  1 of 7 = 14 percent (truncated)
#   R4  no records = 0 percent (0 red of 0 batches)
#   R5  an unread red counts red, as red= does
#   R6  a red record 8 days old is outside the 7-day window
#   R7  --days 3: the label and the window follow it
#   R8  budget low: rc 0, no rate line
#   B   the fake gh saw only harness-ci.yml run-list paths
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=1791000000
REPO=example-org/cromford

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$T/path"
# Stubs first: scratch_install_closure never clobbers a file already there.
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${FAKE_BUDGET_LOW:-1}"; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return 0; }
SH
cat > "$T/path/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "${path%%\?*}" in
  repos/*/actions/workflows/harness-ci.yml/runs) echo '{"total_count":0,"workflow_runs":[]}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/ci-batch-red-report.sh)"; echo "ci-batch-red-report.bh-8267: 0 passed, 1 failed"; exit 1; }

REC="$HH/state/ci-batch-red/runs"
TSV="$HH/state/ci-batch-red/latest.tsv"
LOG="$HH/logs/ci-batch-red.log"
NEXT=1000
reset() { local p; for p in state logs calls.txt; do scratch_rm "$HH/$p"; done; mkdir -p "$REC" "$HH/logs"; }
# seed <n> <red|green> <age-s> [unread] — n records, each with a new id
seed() {
  local i id
  for (( i = 0; i < $1; i++ )); do
    NEXT=$(( NEXT + 1 )); id=$NEXT
    printf 'run %s attempt 1 created %s concl %s tree t%s prs %s%s\n' \
      "$id" "$(( NOW - $3 ))" "$2" "$id" "$id" "${4:+ $4}" > "$REC/$id"
    [ "$2" = red ] && printf 'fail\ttests/x-%s.sh\t1\n' "$id" >> "$REC/$id"
  done
}
drive() { # drive [ENV=val...] [-- args...]; stdout to out.txt, all gh argv to all-calls.txt
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  ( export HARNESS="$HH" NOW PATH="$T/path:$PATH" CI_BATCH_RED_REPO="$REPO"
    unset CI_BATCH_RED_DAYS
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-batch-red-report.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
  [ -f "$HH/calls.txt" ] && cat "$HH/calls.txt" >> "$T/all-calls.txt"
  return 0
}
line1() { head -n 1 "$T/out.txt"; }
want() { # want <case> <expected line 1>
  [ "$RC" = 0 ] && [ "$(line1)" = "$2" ] && ok || bad "$1: rc=$RC line 1 = '$(line1)', want '$2'"
}
DAY=86400
: > "$T/all-calls.txt"

# ── R1: 4 red of 10, dry run then a normal run on the same seed ───────────────
reset; seed 4 red 3600; seed 6 green 7200
drive -- --dry-run
L40='ci-batch-red: red-batch rate, last 7 days: 40 percent (4 red of 10 batches)'
want R1-dry "$L40"
[ "$(sed -n 2p "$T/out.txt")" = "$(printf 'suite\tkind\tred_batches\tgreen_batches_since\tgate_missed\tretry_green\tprs')" ] \
  && ok || bad "R1-dry: line 2 is not the TSV column row: '$(sed -n 2p "$T/out.txt")'"
drive
want R1-run "$L40"
[ "$(wc -l < "$T/out.txt")" -eq 1 ] && ok || bad "R1-run: a normal run prints only the rate line: $(cat "$T/out.txt")"
[ "$(head -n 1 "$TSV" 2>/dev/null)" = "$(printf 'suite\tkind\tred_batches\tgreen_batches_since\tgate_missed\tretry_green\tprs')" ] \
  && ok || bad "R1-run: latest.tsv line 1 is not the column row"
grep -q ' red=4 green=6 red_rate=40 ' "$LOG" 2>/dev/null && ok || bad "R1-run: the log line's red_rate is not 40: $(cat "$LOG" 2>/dev/null)"

# ── R2-R5: the arithmetic ────────────────────────────────────────────────────
reset; seed 3 red 3600; seed 17 green 3600; drive -- --dry-run
want R2 'ci-batch-red: red-batch rate, last 7 days: 15 percent (3 red of 20 batches)'
reset; seed 1 red 3600; seed 6 green 3600; drive -- --dry-run
want R3 'ci-batch-red: red-batch rate, last 7 days: 14 percent (1 red of 7 batches)'
reset; drive -- --dry-run
want R4 'ci-batch-red: red-batch rate, last 7 days: 0 percent (0 red of 0 batches)'
reset; seed 2 red 3600; seed 1 red 3600 unread; seed 7 green 3600; drive -- --dry-run
want R5 'ci-batch-red: red-batch rate, last 7 days: 30 percent (3 red of 10 batches)'

# ── R6: a red record past the window is not counted ──────────────────────────
reset; seed 4 red 3600; seed 6 green 7200; seed 1 red $(( 8 * DAY )); drive -- --dry-run
want R6 "$L40"

# ── R7: --days 3 ─────────────────────────────────────────────────────────────
reset; seed 2 red 3600; seed 2 green 3600; seed 3 red $(( 5 * DAY )); seed 1 green $(( 4 * DAY )); drive -- --dry-run --days 3
want R7 'ci-batch-red: red-batch rate, last 3 days: 50 percent (2 red of 4 batches)'

# ── R8: budget low prints no rate line ───────────────────────────────────────
reset; seed 4 red 3600; drive FAKE_BUDGET_LOW=0 -- --dry-run
[ "$RC" = 0 ] && ! grep -q 'red-batch rate' "$T/out.txt" && ok || bad "R8: rc=$RC, a budget-low tick printed a rate line: $(cat "$T/out.txt")"

# ── B: 0 network calls; the fake gh saw only the run-list path ───────────────
[ -s "$T/all-calls.txt" ] && ok || bad "B: the fake gh was never called (the seam was not driven)"
! grep -q . <<<"$(grep -v 'actions/workflows/harness-ci.yml/runs' "$T/all-calls.txt")" \
  && ok || bad "B: a gh call other than the run list: $(grep -v 'harness-ci.yml/runs' "$T/all-calls.txt" | head -3)"
[ "$(grep -c 'api.github.com\|https://' "$T/all-calls.txt")" = 0 ] && ok || bad "B: a gh call names a URL"

echo "ci-batch-red-report.bh-8267: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
