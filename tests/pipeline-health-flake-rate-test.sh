#!/bin/bash
# tests/pipeline-health-flake-rate-test.sh — the flake-rate line in
# bin/pipeline-health.sh, extracted VERBATIM by its markers and driven with a
# stub ledger reader.
#
#   Flake rate is flaky reds / all reds over 7 days, counted in DISTINCT
#   (workflow, head) reds — not in ledger rows, because one red head carries
#   one row per failing test and a repo with a chatty suite would otherwise
#   look flakier than a repo with a quiet one. It is a MEASUREMENT: one line in
#   logs/pipeline-health.log, never an ALERTS page, because nobody has yet
#   decided what rate is too high and a threshold invented here would be noise.
#
# Run from anywhere: tests/pipeline-health-flake-rate-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

awk '/^# >>> flake rate/{f=1;next} /^# <<< flake rate/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the flake-rate block — markers missing?"

D=$(date -u +%Y-%m-%d)
OLDS=$(( $(date -u +%s) - 20 * 86400 ))
OLD=$(date -u -d "@$OLDS" +%Y-%m-%d 2>/dev/null || date -u -r "$OLDS" +%Y-%m-%d)
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$T/ledger.tsv"; }
drive() {
  : > "$T/alerts.txt"; : > "$T/logs/pipeline-health.log"
  ( export HARNESS="$T" T="$T"
    env FLAKERATE_EVERY=0 bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s)
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      metric_flakes_list() { cat "$T/ledger.tsv" 2>/dev/null; }
      . "$0"' "$T/blk.sh" 2>"$T/err.txt" )
}
W=.github/workflows/ci.yml; W2=.github/workflows/e2e.yml

# 1. three distinct red heads, one of them flaky -> 1/3
: > "$T/ledger.tsv"
row "$D" o/r "$W" "a > b" h1 flake
row "$D" o/r "$W" "c > d" h1 flake     # same head: still ONE red
row "$D" o/r "$W" "job:unit" h2 red
row "$D" o/r "$W" "job:unit" h3 red
drive
grep -q 'flake rate 7d' "$T/logs/pipeline-health.log" \
  && ok || bad "no flake-rate line written: $(cat "$T/logs/pipeline-health.log") err=$(cat "$T/err.txt")"
grep -q 'o/r 1/3' "$T/logs/pipeline-health.log" \
  && ok || bad "one flaky head of three red heads must read 1/3, not 2/4: $(cat "$T/logs/pipeline-health.log")"
[ -s "$T/alerts.txt" ] && bad "the flake rate is a measurement, not a page: $(cat "$T/alerts.txt")" || ok

# 2. two workflows on ONE head are two reds — the unit is (workflow, head)
: > "$T/ledger.tsv"
row "$D" o/r "$W"  "a > b"    h1 flake
row "$D" o/r "$W2" "job:e2e"  h1 red
drive
grep -q 'o/r 1/2' "$T/logs/pipeline-health.log" \
  && ok || bad "two workflows red on one head are two reds: $(cat "$T/logs/pipeline-health.log")"

# 3. rows older than the window are not counted
: > "$T/ledger.tsv"
row "$OLD" o/r "$W" "a > b"   h9 flake
row "$D"   o/r "$W" "job:unit" h1 red
drive
grep -q 'o/r 0/1' "$T/logs/pipeline-health.log" \
  && ok || bad "a 20-day-old flake must fall out of the 7d window: $(cat "$T/logs/pipeline-health.log")"

# 4. every repo with reds is named, each with its own rate
: > "$T/ledger.tsv"
row "$D" o/r  "$W" "a > b"    h1 flake
row "$D" o/r2 "$W" "job:unit" h1 red
drive
grep -q 'o/r 1/1' "$T/logs/pipeline-health.log" && grep -q 'o/r2 0/1' "$T/logs/pipeline-health.log" \
  && ok || bad "each repo gets its own rate: $(cat "$T/logs/pipeline-health.log")"

# 5. an empty ledger writes nothing at all (no 0/0, no divide by zero)
: > "$T/ledger.tsv"
drive
[ -s "$T/logs/pipeline-health.log" ] && bad "an empty ledger must write no line: $(cat "$T/logs/pipeline-health.log")" || ok

# 6. the hourly stamp throttles it
: > "$T/ledger.tsv"; row "$D" o/r "$W" "a > b" h1 flake
drive
grep -q 'o/r 1/1' "$T/logs/pipeline-health.log" && ok || bad "first run must write"
: > "$T/logs/pipeline-health.log"
( export HARNESS="$T" T="$T"
  bash -c 'set -uo pipefail; H="$T"; NOW=$(date +%s); STAMP(){ echo TS; }
    alert(){ :; }; metric_flakes_list(){ cat "$T/ledger.tsv"; }; . "$0"' "$T/blk.sh" 2>/dev/null )
[ -s "$T/logs/pipeline-health.log" ] && bad "the stamp must throttle the second run inside the hour" || ok

echo "pipeline-health-flake-rate-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
