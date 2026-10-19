#!/bin/bash
# tests/lead-gates-state-sweep.bh-7235-test.sh — BH-7235 (BH-5878.1, slice C1):
# the retention gate of the worklist gates' state, lg_tick_state_sweep in
# bin/lib/lead-gates.d/99-state-sweep.sh. The gates write per-head markers and
# ledger rows in state/lead-review-enqueue/ on every box, and only the enqueue
# (hub only, and no longer started) pruned that dir. Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh)
# with a seeded state/lead-review-enqueue/:
#   R1  no stamp: nothing deleted, one `state-sweep: dry-run files=<n> rows=<n>`
#       line with the true counts, the stamp written.
#   R2  the stamp 1 h old: no sweep line.
#   R3  the stamp 25 h old: 7.5-day risk-pub-*, traced-*, selfcheck-*,
#       silence/note-* deleted, 6-day ones kept; risk.tsv and requested.tsv
#       rows older than 7 days dropped, a 6-day row kept.
#   R4  the same tick still starts the worklist job (the sweep never holds).
#   R5  the window 0: nothing deleted, no sweep line. R6 the window `abc`: one
#       log line, nothing deleted (unset reads the same: the registry was
#       not read).
#   R7  a row whose first column is not an epoch, and skip-last.tsv /
#       ledger.tsv of any age, are kept.
#   R8  lane_env_apply lead-review on a scratch registry exports 7, and a
#       settings row lane.lead-review.lead_review_gate_state_keep_days moves it.
#   M1  (D1) 99-state-sweep.sh removed: R3's 7.5-day files stay.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-state-sweep.bh-7235-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
# The window is a required registry knob: the fixture carries no lane
# registry, so the suite exports the registry default (R8 proves it).
export LEAD_REVIEW_GATE_STATE_KEEP_DAYS=7
GD="$H/bin/lib/lead-gates.d"
[ -r "$DIR/bin/lib/lead-gates.d/99-state-sweep.sh" ] && [ -r "$GD/99-state-sweep.sh" ] && ok || bad "setup: bin/lib/lead-gates.d/99-state-sweep.sh not installed"
H1=$(printf '%040d' 101)
ST="$H/state/lead-review-enqueue"
STAMPF="$H/state/lead-review-gates/state-sweep.stamp"
NOWS=$(date +%s)
age() { touch -d "@$(( NOWS - $2 * 3600 ))" "$1"; }
ep() { echo $(( NOWS - $1 * 86400 )); }
OLD="risk-pub-x traced-x selfcheck-x selfcheck-notes-x inbuild-wait-x alerted-x review-tier-x"
seed() {
  local f
  mkdir -p "$ST/silence"
  for f in $OLD; do
    : > "$ST/$f-old"; age "$ST/$f-old" 180
    : > "$ST/$f-new"; age "$ST/$f-new" 144
  done
  for f in note-x scanned-x; do
    : > "$ST/silence/$f-old"; age "$ST/silence/$f-old" 180
    : > "$ST/silence/$f-new"; age "$ST/silence/$f-new" 144
  done
  for f in skip-last.tsv ledger.tsv; do : > "$ST/$f"; age "$ST/$f" 2400; done
  printf '%s\texample-org/cromford\t1\t%s\tlow\n' "$(ep 8)" "$H1" "$(ep 6)" "$H1" > "$ST/risk.tsv"
  printf 'not-an-epoch\texample-org/cromford\t1\t%s\tlow\n' "$H1" >> "$ST/risk.tsv"
  printf '%s\texample-org/cromford\t1\t%s\tid\n' "$(ep 8)" "$H1" > "$ST/requested.tsv"
}
# The seed holds 7x2 + 2x2 = 18 files, 9 of them 7.5 days old (gate 60's own
# review-tier-* prune, -mtime +7, takes 8 full days, so it leaves them), and 2
# rows past 7 days (one in risk.tsv, one in requested.tsv). A case that counts
# rows starts no review: a started review's gates append rows.
olds() { local f n=0; for f in "$ST"/*-old "$ST"/silence/*-old; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
news() { local f n=0; for f in "$ST"/*-new "$ST"/silence/*-new; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
rows() { wc -l < "$ST/$1" | tr -d ' '; }
sweeplines() { lwf_cnt 'state-sweep:' "$L"; }

# ── R1: no stamp: a dry run ──
lgf_reset; seed
lwf_tick
[ "$RC" = 0 ] && ok || bad "R1 rc=$RC $(cat "$T/out")"
[ "$(lwf_cnt 'state-sweep: dry-run files=9 rows=2 keep=7d' "$L")" = 1 ] && ok || bad "R1 dry-run line: $(grep state-sweep "$L")"
[ "$(olds)" = 9 ] && [ "$(news)" = 9 ] && ok || bad "R1 the dry run deleted: olds=$(olds) news=$(news)"
[ "$(rows risk.tsv)" = 3 ] && [ "$(rows requested.tsv)" = 1 ] && ok || bad "R1 the dry run dropped rows"
[ -e "$STAMPF" ] && ok || bad "R1 no stamp at $STAMPF"

# ── R2: the stamp 1 h old: no sweep ──
lwf_reset; age "$STAMPF" 1
lwf_tick
[ "$(sweeplines)" = 0 ] && ok || bad "R2 a sweep inside 24 h: $(grep state-sweep "$L")"
[ "$(olds)" = 9 ] && ok || bad "R2 deleted inside 24 h"

# ── R3, R7: the stamp 25 h old: the sweep deletes ──
lwf_reset; age "$STAMPF" 25
lwf_tick
[ "$(lwf_cnt 'state-sweep: deleted files=9 rows=2 keep=7d' "$L")" = 1 ] && ok || bad "R3 delete line: $(grep state-sweep "$L")"
[ "$(olds)" = 0 ] && ok || bad "R3 7.5-day markers left: $(olds); $(ls "$ST" "$ST/silence")"
[ "$(news)" = 9 ] && ok || bad "R3 6-day markers deleted: $(news) of 9 left"
[ "$(rows risk.tsv)" = 2 ] && grep -q "^$(ep 6)	" "$ST/risk.tsv" && ! grep -q "^$(ep 8)	" "$ST/risk.tsv" && ok || bad "R3 risk.tsv: $(cat "$ST/risk.tsv")"
[ "$(rows requested.tsv)" = 0 ] && ok || bad "R3 requested.tsv: $(cat "$ST/requested.tsv")"
grep -q '^not-an-epoch	' "$ST/risk.tsv" && ok || bad "R7 the non-epoch row was dropped"
[ -e "$ST/skip-last.tsv" ] && [ -e "$ST/ledger.tsv" ] && ok || bad "R7 a file outside the patterns was deleted"
[ -n "$(find "$STAMPF" -mmin -60)" ] && ok || bad "R3 the stamp was not renewed"

# ── R4: a sweep tick still starts the worklist job ──
lgf_reset; seed; mkdir -p "${STAMPF%/*}"; : > "$STAMPF"; age "$STAMPF" 25; lgf_needs "101:$H1"
lwf_tick
[ "$(lwf_cnt 'state-sweep: deleted files=9 ' "$L")" = 1 ] && ok || bad "R4 no delete line: $(grep state-sweep "$L")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R4 the sweep tick started no job: $(cat "$L")"

# ── R5: the window 0: off ──
lgf_reset; seed; mkdir -p "${STAMPF%/*}"; : > "$STAMPF"; age "$STAMPF" 25
export LEAD_REVIEW_GATE_STATE_KEEP_DAYS=0
lwf_tick
export LEAD_REVIEW_GATE_STATE_KEEP_DAYS=7
[ "$(sweeplines)" = 0 ] && ok || bad "R5 a sweep line with the window off: $(grep state-sweep "$L")"
[ "$(olds)" = 9 ] && [ "$(rows risk.tsv)" = 3 ] && ok || bad "R5 deleted with the window off"

# ── R6: the window is not a whole number ──
lgf_reset; seed; mkdir -p "${STAMPF%/*}"; : > "$STAMPF"; age "$STAMPF" 25
export LEAD_REVIEW_GATE_STATE_KEEP_DAYS=abc
lwf_tick
export LEAD_REVIEW_GATE_STATE_KEEP_DAYS=7
[ "$(lwf_cnt "state-sweep: LEAD_REVIEW_GATE_STATE_KEEP_DAYS='abc' is not a whole number; nothing deleted" "$L")" = 1 ] \
  && ok || bad "R6 knob line: $(grep state-sweep "$L")"
[ "$(olds)" = 9 ] && [ "$(rows risk.tsv)" = 3 ] && ok || bad "R6 deleted with a bad window"

# ── R8: the registry defaults and a settings row ──
R8="$T/r8"; mkdir -p "$R8/bin" "$R8/state" "$R8/catalog"
scratch_install_closure bin/lanes-build.sh "$R8" >/dev/null || bad "R8 closure of bin/lanes-build.sh"
scratch_install_closure bin/lead-review.sh "$R8" >/dev/null || bad "R8 closure of bin/lead-review.sh"
cp -R "$DIR/catalog/lanes.d" "$R8/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$R8" --write >/dev/null 2>&1 || bad "R8 lanes-build --write"
R8NOW=1792000000
r8() {
  jq -nc --argjson v "$1" --argjson t "$R8NOW" '{fetched_at:$t, values:$v}' > "$R8/state/settings-cache.json"
  env -i PATH="$PATH" HOME="$T" TMPDIR="$T" HARNESS="$R8" LANE_GATE_NOW="$R8NOW" LANE_GATE_CACHE_S=600 JOBS_URL=https://jobs.invalid \
    bash -c ". \"$R8/bin/lib/lane-gate.sh\" || exit 9; lane_env_apply lead-review >/dev/null 2>&1; printf '%s' \"\${LEAD_REVIEW_GATE_STATE_KEEP_DAYS:-unset}\"" 2>"$T/r8.err"
}
got=$(r8 '{}')
[ "$got" = 7 ] && ok || bad "R8 registry default '$got' (want 7): $(cat "$T/r8.err")"
got=$(r8 '{"lane.lead-review.lead_review_gate_state_keep_days":"3"}')
[ "$got" = 3 ] && ok || bad "R8 with the settings row '$got' (want 3): $(cat "$T/r8.err")"

# ── M1: no 99-state-sweep.sh: R3's 7.5-day files stay ──
mv "$GD/99-state-sweep.sh" "$T/99.off"
lgf_reset; seed; mkdir -p "${STAMPF%/*}"; : > "$STAMPF"; age "$STAMPF" 25
lwf_tick
[ "$RC" = 0 ] && ok || bad "M1 rc=$RC"
[ "$(olds)" = 0 ] && bad "M1 the 7.5-day files went with 99-state-sweep.sh removed" || ok
mv "$T/99.off" "$GD/99-state-sweep.sh"

echo "lead-gates-state-sweep.bh-7235: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
