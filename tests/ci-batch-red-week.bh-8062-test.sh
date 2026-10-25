#!/bin/bash
# tests/ci-batch-red-week.bh-8062-test.sh — BH-8062 T5: bin/ci-batch-red-report.sh
# writes one `ci-batch-red-week:` line per ISO week (the last complete Mon-Sun
# UTC week), from the batch records already on disk, so the 15 percent red-batch
# target is visible. Driven against a scratch harness with a fake `gh` on PATH
# that serves an empty run list (0 network calls), records seeded in the format
# the lane writes (`run <id> attempt <n> created <epoch> concl red|green ...`),
# and the clock pinned with NOW.
#
#   W1  3 red / 17 green last week: one line, red_rate=15 target=15 met=yes
#   W2  the second run the same week writes no line
#   W3  4 red / 16 green: red_rate=20 met=no
#   W4  an empty week: red_rate=- met=no-data
#   W5  --dry-run prints the line, writes no marker and no log line
#   W6  Mon 2026-10-26 06:37Z -> 2026-W43; Sun 2026-10-25 -> 2026-W42
#   W7  a year boundary: Mon 2027-01-04 -> 2026-W53; Mon 2026-01-05 -> 2026-W01
#   W8  CI_BATCH_RED_TARGET_PCT=25: target=25 met=yes for 4/16
#   W9  records of other weeks are not counted; KEEP_DAYS shorter than the
#       week's age: met=no-data why=pruned
#   W10 week markers past CI_BATCH_RED_WEEK_KEEP_DAYS are pruned
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-batch-red-week.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REPO=example-org/cromford
ep() { date -u -d "$1" +%s; }
MON=$(ep 2026-10-26T06:37:00Z)       # a Monday: the last complete week is 2026-W43 (Oct 19-25)
W43=$(ep 2026-10-19T00:00:00Z)

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$T/path"
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return 1; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return 0; }
SH
# The fake gh: an empty harness-ci.yml run list, anything else exits 1.
cat > "$T/path/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
case "$*" in
  *actions/workflows/harness-ci.yml/runs*) echo '{"total_count":0,"workflow_runs":[]}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/ci-batch-red-report.sh)"; echo "ci-batch-red-week: 0 passed, 1 failed"; exit 1; }
[ -f "$DIR/bin/ci-batch-red-report.sh" ] || bad "setup: bin/ci-batch-red-report.sh is missing"

REC="$HH/state/ci-batch-red/runs"
LOG="$HH/logs/ci-batch-red.log"
WLOG="$HH/logs/ci-batch-red-week.log"
reset() { local p; for p in state logs calls.txt; do scratch_rm "$HH/$p"; done; mkdir -p "$REC" "$HH/logs"; ID=1000; }
# seed <created epoch> <red|green> <n> — n records in the lane's own format
seed() {
  local i
  for (( i = 0; i < $3; i++ )); do
    ID=$(( ID + 1 ))
    echo "run $ID attempt 1 created $(( $1 + i * 60 )) concl $2 tree t$ID prs -" > "$REC/$ID"
  done
}
drive() { # drive <now> [ENV=val...] [-- args...]
  local now="$1" envs=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  ( export HARNESS="$HH" NOW="$now" PATH="$T/path:$PATH" CI_BATCH_RED_REPO="$REPO"
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-batch-red-report.sh" "$@" ) >"$T/out.txt" 2>&1
  RC=$?
}
wlines() { grep -c 'ci-batch-red-week:' "$WLOG" 2>/dev/null; }
wline() { grep 'ci-batch-red-week:' "$WLOG" 2>/dev/null | tail -n1; }

# ── W1 / W2: 3 red, 17 green in W43; a week before it that must not count
reset
seed $(( W43 + 3600 )) red 3
seed $(( W43 + 86400 )) green 17
seed $(( W43 - 2 * 86400 )) red 5           # W42: outside the week
seed $(( MON - 3600 )) red 2                # Mon of W44: outside the week
drive "$MON"
[ "$RC" = 0 ] && ok || bad "W1: rc 0 ($RC: $(cat "$T/out.txt"))"
[ "$(wlines)" = 1 ] && ok || bad "W1: exactly one week line (got $(wlines): $(cat "$WLOG" 2>/dev/null))"
case "$(wline)" in
  *" ci-batch-red-week: repo=$REPO week=2026-W43 red=3 green=17 red_rate=15 target=15 met=yes") ok ;;
  *) bad "W1: the week line (got '$(wline)')" ;;
esac
[ -e "$HH/state/ci-batch-red/week-2026-W43" ] && ok || bad "W1: the week marker is written"
grep -q '^.* ci-batch-red: repo=' "$LOG" && ok || bad "W1: the tick's own line is still written"
[ "$(grep -c . "$LOG" 2>/dev/null)" = 1 ] && ! grep -q 'ci-batch-red-week:' "$LOG" && ok \
  || bad "W1: the tick log keeps one line a tick; the week line is in its own log ($(cat "$LOG" 2>/dev/null))"
drive "$MON"
[ "$(wlines)" = 1 ] && ok || bad "W2: a second run the same week writes no week line (got $(wlines))"
drive $(( MON + 3 * 86400 ))
[ "$(wlines)" = 1 ] && ok || bad "W2: a run later the same week writes no week line (got $(wlines))"

# ── W3: 4 red, 16 green
reset
seed $(( W43 + 3600 )) red 4
seed $(( W43 + 2 * 86400 )) green 16
drive "$MON"
case "$(wline)" in *" week=2026-W43 red=4 green=16 red_rate=20 target=15 met=no") ok ;; *) bad "W3: 4/16 is met=no (got '$(wline)')" ;; esac

# ── W8: the target knob
reset
seed $(( W43 + 3600 )) red 4
seed $(( W43 + 2 * 86400 )) green 16
drive "$MON" CI_BATCH_RED_TARGET_PCT=25
case "$(wline)" in *" red=4 green=16 red_rate=20 target=25 met=yes") ok ;; *) bad "W8: target 25 (got '$(wline)')" ;; esac
reset
seed $(( W43 + 3600 )) red 4
drive "$MON" CI_BATCH_RED_TARGET_PCT=500
case "$(wline)" in *" target=15 met=no") ok ;; *) bad "W8: an out-of-range target is the default 15 (got '$(wline)')" ;; esac

# ── W4: an empty week
reset
seed $(( W43 - 3 * 86400 )) red 2
drive "$MON"
case "$(wline)" in *" week=2026-W43 red=0 green=0 red_rate=- target=15 met=no-data") ok ;; *) bad "W4: empty week (got '$(wline)')" ;; esac

# ── W5: --dry-run
reset
seed $(( W43 + 3600 )) red 3
seed $(( W43 + 86400 )) green 17
drive "$MON" -- --dry-run
grep -q '^ci-batch-red-week: repo=.* week=2026-W43 red=3 green=17 red_rate=15 target=15 met=yes$' "$T/out.txt" && ok \
  || bad "W5: --dry-run prints the week line ($(cat "$T/out.txt"))"
[ ! -e "$HH/state/ci-batch-red/week-2026-W43" ] && ok || bad "W5: --dry-run writes no marker"
[ ! -s "$LOG" ] && [ ! -s "$WLOG" ] && ok || bad "W5: --dry-run writes no log line"

# ── W6: which week
reset
drive "$(ep 2026-10-25T12:00:00Z)"
case "$(wline)" in *" week=2026-W42 "*) ok ;; *) bad "W6: a Sunday reports the week before its own (got '$(wline)')" ;; esac
drive "$MON"
case "$(wline)" in *" week=2026-W43 "*) ok ;; *) bad "W6: Monday 2026-10-26 reports 2026-W43 (got '$(wline)')" ;; esac
[ "$(wlines)" = 2 ] && ok || bad "W6: one line per week (got $(wlines))"

# ── W7: the year boundary
reset
seed "$(ep 2026-12-31T10:00:00Z)" red 1
seed "$(ep 2027-01-03T10:00:00Z)" green 3
drive "$(ep 2027-01-04T06:37:00Z)"
case "$(wline)" in *" week=2026-W53 red=1 green=3 red_rate=25 target=15 met=no") ok ;; *) bad "W7: 2026-W53 (got '$(wline)')" ;; esac
reset
drive "$(ep 2026-01-05T06:37:00Z)"     # the week of Mon 2025-12-29 is ISO 2026-W01
case "$(wline)" in *" week=2026-W01 "*) ok ;; *) bad "W7: the week of 2025-12-29 is 2026-W01, the ISO year (got '$(wline)')" ;; esac

# ── W9: the week is older than the record retention
reset
seed $(( W43 + 3600 )) red 3
drive "$MON" CI_BATCH_RED_KEEP_DAYS=7
case "$(wline)" in *" week=2026-W43 "*" red_rate=- target=15 met=no-data why=pruned") ok ;; *) bad "W9: pruned week is no-data (got '$(wline)')" ;; esac

# ── W10: week marker retention
reset
mkdir -p "$HH/state/ci-batch-red"
echo "week 2026-W20 start $(ep 2026-05-11T00:00:00Z)" > "$HH/state/ci-batch-red/week-2026-W20"
echo "week 2026-W40 start $(ep 2026-09-28T00:00:00Z)" > "$HH/state/ci-batch-red/week-2026-W40"
drive "$MON"
[ ! -e "$HH/state/ci-batch-red/week-2026-W20" ] && ok || bad "W10: a marker past 90 days is pruned"
[ -e "$HH/state/ci-batch-red/week-2026-W40" ] && ok || bad "W10: a recent marker stays"
[ -e "$HH/state/ci-batch-red/week-2026-W43" ] && ok || bad "W10: this week's marker is written"

echo "ci-batch-red-week: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
