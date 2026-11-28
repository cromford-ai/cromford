#!/bin/bash
# tests/prr-read-counter.bh-10211-test.sh — BH-10211 C0: the shadow-read
# counter of prr_read (bin/lib/prr-shadow.sh -> bin/lib/prr-count.sh).
#
# What is pinned:
#   kinds    a shadow read adds 1 to exactly one kind in
#            logs/prr-count/<lane>/<UTC day>.tsv: agree (equal norms, 0 log
#            lines), mismatch (differ, 1 PRR_SHADOW line), miss + miss.<word>
#            (record miss), skip (GitHub rc != 0, or an empty norm). prr_read's
#            rc and out file do not change.
#   words    a miss word outside [a-z0-9_:.-] or over 40 chars is miss.other.
#   steps    off and record write no counter file.
#   days     two UTC days give two files; first and last are set.
#   keep     PRR_COUNT_KEEP_DAYS=3: a new day file deletes a 4-day-old file
#            and keeps a 2-day-old file.
#   lock     a held lock: prr_read keeps its rc, returns in time, the file
#            does not change.
#   lane     a bad lane id is rc 2 and writes nothing.
#   hit-rc   (BH-10213) a record hit-rc:<n> equal to the GitHub rc is agree
#            with 0 log lines; a different rc is mismatch with 1 PRR_SHADOW line.
#   nostate  the counter never writes under state/ (box-local, logs/ only).
# Run from anywhere: bash tests/prr-read-counter.bh-10211-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"; mkdir -p "$HARNESS/logs" "$T/tmp"
export TMPDIR="$T/tmp" HARNESS_TEST_SANDBOX=1
unset GH_SOURCE GH_SOURCE_LANE H PRR_COUNT_KEEP_DAYS PRR_COUNT_LOCK_S
# shellcheck source=bin/lib/prr-shadow.sh
. "$DIR/bin/lib/prr-shadow.sh" || { echo "FAIL: prr-shadow.sh did not source"; exit 1; }
LOG="$HARNESS/logs/prr-shadow.log"
NOW0=1795000000   # 2026-11-19T...Z
export PRR_COUNT_NOW=$NOW0
day() { date -u -d "@$1" +%F; }
U=$$   # unique lane ids per run
cfile() { printf '%s/logs/prr-count/%s/%s.tsv' "$HARNESS" "$1" "$(day "${2:-$PRR_COUNT_NOW}")"; }
cval() { awk -F'\t' -v k="$2" '$1 == k { print $2; f=1 } END { if (!f) print 0 }' "$(cfile "$1" "${3:-$PRR_COUNT_NOW}")" 2>/dev/null || echo 0; }
nlog() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

rec_fn() { [ "${REC_RC:-0}" = 0 ] || { echo "${REC_WHY:-stale}"; return "$REC_RC"; }; printf '%s' "${REC_OUT:-}" > "$1"; [ -z "${REC_HITRC:-}" ] || echo "hit-rc:$REC_HITRC"; }
gh_fn()  { printf '%s' "$GH_OUT" > "$1"; return "${GH_RC:-0}"; }
norm_fn() { [ -n "${NORM_EMPTY:-}" ] && return 0; jq -c '[.[] | {n, t}] | sort_by(.n)' "$1"; }
A='[{"n":1,"t":"a"}]'; B='[{"n":1,"t":"b"}]'

NRUN=0
run() { # run <lane> <step> -> RC, OUTV
  NRUN=$((NRUN+1)); local out="$T/out.$NRUN"
  GH_SOURCE="$2" GH_SOURCE_LANE="$1" prr_read "$1" k1 "$out" rec_fn gh_fn norm_fn; RC=$?
  OUTV=$(cat "$out" 2>/dev/null); rm -f "$out"
}

# ---- agree ---------------------------------------------------------------------
L="agree-$U"; : > "$LOG"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
[ "$RC" = 0 ] && ok || bad "agree: rc want 0 got $RC"
[ "$OUTV" = "$A" ] && ok || bad "agree: out must hold the GitHub value, got '$OUTV'"
[ "$(cval "$L" agree)" = 1 ] && ok || bad "agree: agree want 1, file: $(cat "$(cfile "$L")" 2>/dev/null)"
[ "$(cval "$L" mismatch)" = 0 ] && ok || bad "agree: mismatch want 0"
[ -s "$LOG" ] && bad "agree: log must stay empty: $(cat "$LOG")" || ok
REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
[ "$(cval "$L" agree)" = 2 ] && ok || bad "agree: second read want 2 got $(cval "$L" agree)"
[ "$(cval "$L" first)" = "$NOW0" ] && ok || bad "agree: first want $NOW0 got $(cval "$L" first)"

# ---- mismatch ------------------------------------------------------------------
L="mis-$U"; : > "$LOG"
REC_RC=0 REC_OUT="$A" GH_OUT="$B" run "$L" shadow
[ "$RC" = 0 ] && ok || bad "mismatch: rc want 0 got $RC"
[ "$OUTV" = "$B" ] && ok || bad "mismatch: out must hold the GitHub value"
[ "$(cval "$L" mismatch)" = 1 ] && ok || bad "mismatch: want 1 got $(cval "$L" mismatch)"
[ "$(cval "$L" agree)" = 0 ] && ok || bad "mismatch: agree want 0"
[ "$(nlog "PRR_SHADOW lane=$L ")" = 1 ] && ok || bad "mismatch: want 1 PRR_SHADOW line: $(cat "$LOG")"

# ---- miss ----------------------------------------------------------------------
L="miss-$U"
REC_RC=1 REC_WHY='field:run_id' GH_OUT="$A" run "$L" shadow
[ "$RC" = 0 ] && ok || bad "miss: rc want 0 (GitHub) got $RC"
[ "$(cval "$L" miss)" = 1 ] && ok || bad "miss: miss want 1"
[ "$(cval "$L" 'miss.field:run_id')" = 1 ] && ok || bad "miss: miss.field:run_id want 1: $(cat "$(cfile "$L")" 2>/dev/null)"
REC_RC=1 REC_WHY='bad word/x' GH_OUT="$A" run "$L" shadow
REC_RC=1 REC_WHY="$(printf 'x%.0s' $(seq 1 41))" GH_OUT="$A" run "$L" shadow
[ "$(cval "$L" miss.other)" = 2 ] && ok || bad "miss: a space/slash word and a 41-char word go to miss.other: $(cat "$(cfile "$L")")"
[ "$(cval "$L" miss)" = 3 ] && ok || bad "miss: total want 3"
grep -q '/' <(cut -f1 "$(cfile "$L")" | grep -v '^miss\.field:run_id$') && bad "miss: a key holds a slash" || ok

# ---- skip ----------------------------------------------------------------------
L="skip-$U"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" GH_RC=3 run "$L" shadow
[ "$RC" = 3 ] && ok || bad "skip: rc want 3 got $RC"
[ "$(cval "$L" skip)" = 1 ] && ok || bad "skip: GitHub rc 3 want skip 1"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" NORM_EMPTY=1 run "$L" shadow
[ "$(cval "$L" skip)" = 2 ] && ok || bad "skip: empty norm want skip 2"
[ "$(cval "$L" agree)" = 0 ] && ok || bad "skip: agree want 0"

# ---- hit-rc (BH-10213) ---------------------------------------------------------
L="hitrc-$U"; : > "$LOG"
REC_RC=0 REC_HITRC=1 GH_OUT="$A" GH_RC=1 run "$L" shadow
[ "$RC" = 1 ] && ok || bad "hit-rc: rc want 1 (GitHub) got $RC"
[ "$(cval "$L" agree)" = 1 ] && ok || bad "hit-rc: equal rc want agree 1: $(cat "$(cfile "$L")" 2>/dev/null)"
[ "$(cval "$L" skip)" = 0 ] && ok || bad "hit-rc: equal rc want skip 0"
[ -s "$LOG" ] && bad "hit-rc: equal rc must log nothing: $(cat "$LOG")" || ok
REC_RC=0 REC_HITRC=1 GH_OUT="$A" GH_RC=0 run "$L" shadow
[ "$RC" = 0 ] && ok || bad "hit-rc: rc want 0 (GitHub) got $RC"
[ "$(cval "$L" mismatch)" = 1 ] && ok || bad "hit-rc: different rc want mismatch 1: $(cat "$(cfile "$L")" 2>/dev/null)"
[ "$(cval "$L" agree)" = 1 ] && ok || bad "hit-rc: different rc must not add agree"
[ "$(nlog "PRR_SHADOW lane=$L key=k1 rc_record=1 rc_github=0")" = 1 ] && ok || bad "hit-rc: want 1 rc PRR_SHADOW line: $(cat "$LOG")"

# ---- no state/ write -------------------------------------------------------------
n=$(find "$HARNESS/state" -path '*prr-count*' 2>/dev/null | wc -l)
[ "$n" = 0 ] && ok || bad "nostate: the counter wrote $n path(s) under state/"
[ -d "$HARNESS/logs/prr-count/agree-$U" ] && ok || bad "nostate: the counter must write under logs/prr-count/"

# ---- off / record --------------------------------------------------------------
for st in off record; do
  L="$st-$U"
  REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" "$st"
  [ -e "$HARNESS/logs/prr-count/$L" ] && bad "$st: must write no counter" || ok
done

# ---- two days ------------------------------------------------------------------
L="days-$U"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
PRR_COUNT_NOW=$((NOW0 + 86400 + 60)) REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
PRR_COUNT_NOW=$((NOW0 + 86400 + 120)) REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
n=$(find "$HARNESS/logs/prr-count/$L" -name '*.tsv' | wc -l)
[ "$n" = 2 ] && ok || bad "days: want 2 day files got $n"
[ "$(cval "$L" first $((NOW0 + 86400)))" = $((NOW0 + 86400 + 60)) ] && ok || bad "days: first of day 2"
[ "$(cval "$L" last $((NOW0 + 86400)))" = $((NOW0 + 86400 + 120)) ] && ok || bad "days: last of day 2"
[ "$(cval "$L" agree $((NOW0 + 86400)))" = 2 ] && ok || bad "days: agree of day 2 want 2"

# ---- retention -----------------------------------------------------------------
L="keep-$U"; D="$HARNESS/logs/prr-count/$L"; mkdir -p "$D"
old4="$D/$(day $((NOW0 - 4*86400))).tsv"; old2="$D/$(day $((NOW0 - 2*86400))).tsv"
printf 'agree\t5\n' > "$old4"; : > "$old4.lock"; printf 'agree\t5\n' > "$old2"
PRR_COUNT_KEEP_DAYS=3 REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
[ -e "$old4" ] && bad "keep: a 4-day-old file must go" || ok
[ -e "$old4.lock" ] && bad "keep: its lock must go" || ok
[ -e "$old2" ] && ok || bad "keep: a 2-day-old file must stay"
[ "$(cval "$L" agree)" = 1 ] && ok || bad "keep: today's file want agree 1"

# ---- lock ----------------------------------------------------------------------
L="lock-$U"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
f=$(cfile "$L"); before=$(cat "$f")
flock "$f.lock" sleep 6 & HOLD=$!
sleep 0.5
t0=$(date +%s)
PRR_COUNT_LOCK_S=1 REC_RC=0 REC_OUT="$A" GH_OUT="$A" GH_RC=0 run "$L" shadow
t1=$(date +%s)
[ "$RC" = 0 ] && ok || bad "lock: rc want 0 got $RC"
[ "$OUTV" = "$A" ] && ok || bad "lock: out must hold the GitHub value"
[ $((t1 - t0)) -le 2 ] && ok || bad "lock: prr_read took $((t1 - t0))s with PRR_COUNT_LOCK_S=1"
[ "$(cat "$f")" = "$before" ] && ok || bad "lock: the file must not change under a held lock"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null

# ---- bad lane ------------------------------------------------------------------
prr_count_add '../x' agree; rc=$?
[ "$rc" = 2 ] && ok || bad "lane: ../x want rc 2 got $rc"
[ -e "$HARNESS/state/x" ] || [ -e "$HARNESS/logs/prr-count/../x" ] && bad "lane: ../x wrote a file" || ok
prr_count_add "bad-$U" nonsense; rc=$?
[ "$rc" = 2 ] && ok || bad "kind: an unknown kind want rc 2 got $rc"
# no root: rc 0, no file
( unset HARNESS H; prr_count_add "noroot-$U" agree ); rc=$?
[ "$rc" = 0 ] && ok || bad "root: no root want rc 0 got $rc"

# ---- sandbox root (the trace-safety HIT of 2026-11-27) -------------------------
# R1: HARNESS is a scratch dir: a counted read writes only under it, and the
#     checkout's logs/prr-count does not change.
snap() { find "$DIR/logs/prr-count" -type f 2>/dev/null | LC_ALL=C sort; }
co_before=$(snap)
L="sbx-$U"
REC_RC=0 REC_OUT="$A" GH_OUT="$A" run "$L" shadow
[ "$(cval "$L" agree)" = 1 ] && ok || bad "R1: the scratch root must hold the count"
[ "$(snap)" = "$co_before" ] && ok || bad "R1: the checkout's logs/prr-count changed: $(snap)"
left=$(find "$HARNESS/logs/prr-count/$L" -name '*.tmp.*' 2>/dev/null | head -n1)
[ -z "$left" ] && ok || bad "R1: a tmp file stayed: $left"
# R2: HARNESS is the checkout the lib was sourced from, under
#     HARNESS_TEST_SANDBOX=1 (what tracker-seam-ported.bh-8892 does): rc 0 and
#     nothing is written under that checkout.
CO="$T/co"; mkdir -p "$CO/logs"
scratch_install_closure bin/lib/prr-count.sh "$CO" >/dev/null || bad "R2: closure install failed"
( unset PRR_COUNT_LIB; export HARNESS="$CO"; . "$CO/bin/lib/prr-count.sh"; prr_count_add "co-$U" agree ); rc=$?
[ "$rc" = 0 ] && ok || bad "R2: checkout root want rc 0 got $rc"
[ -e "$CO/logs/prr-count" ] && bad "R2: the counter wrote under its own checkout: $(find "$CO/logs/prr-count" | head -n3)" || ok
# R3: a counted write that succeeds runs no rm (the tracer reads every rm).
tr=$( ( unset PRR_COUNT_LIB; export HARNESS="$T/h3"; . "$DIR/bin/lib/prr-count.sh"; set -x; prr_count_add "tr-$U" agree ) 2>&1 )
[ -s "$T/h3/logs/prr-count/tr-$U/$(day "$PRR_COUNT_NOW").tsv" ] && ok || bad "R3: the scratch count file is missing"
grep -qE '^\++ rm( |$)' <<<"$tr" && bad "R3: a successful write ran rm: $(grep -E '^\++ rm' <<<"$tr" | head -n1)" || ok

echo "prr-read-counter: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
