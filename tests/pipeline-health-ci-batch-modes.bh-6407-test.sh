#!/bin/bash
# tests/pipeline-health-ci-batch-modes.bh-6407-test.sh — the 'ci batch modes'
# line in bin/pipeline-health.sh and its pure counter bin/lib/ci-batch-modes.sh.
#
#   Merge-queue batches per UTC day of completed_at, in three buckets: full
#   (mode full), selected (mode batch-selected), other (any other mode, null
#   included). Every day in the window prints, a quiet day as zeros. A count
#   that could not be taken prints `unknown (<why>)`, never 0. It is a
#   MEASUREMENT: one line in logs/pipeline-health.log, never an alert.
#
# L1-L6 drive ci_batch_modes_eval directly. B0-B9 extract the block VERBATIM
# by its markers and drive it with a stub _jobs_req.
#
# Run from anywhere: tests/pipeline-health-ci-batch-modes.bh-6407-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin/lib"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The lib, installed where the block's own `. "$H/bin/lib/ci-batch-modes.sh"` finds it.
scratch_install_closure bin/lib/ci-batch-modes.sh "$T" >/dev/null \
  && ok || bad "cannot install bin/lib/ci-batch-modes.sh — lib missing?"

# ── Lib ──────────────────────────────────────────────────────────────────────
if [ -r "$T/bin/lib/ci-batch-modes.sh" ]; then
  # shellcheck source=bin/lib/ci-batch-modes.sh
  . "$T/bin/lib/ci-batch-modes.sh"
fi
ev() { ci_batch_modes_eval "$@" 2>/dev/null; }
command -v ci_batch_modes_eval >/dev/null 2>&1 && ok || bad "ci_batch_modes_eval is not defined"

# L1: bad args -> rc 1, no output
GOOD='{"rows":[],"truncated":false}'
l1() {  # <label> <json> <since> <today>
  local out rc
  out=$(ev "$2" "$3" "$4"); rc=$?
  { [ "$rc" = 1 ] && [ -z "$out" ]; } && ok || bad "L1 $1: want rc 1 and no output, got rc $rc out='$out'"
}
l1 "bad since"        "$GOOD"        2026-13-1  2026-10-13
l1 "since > today"    "$GOOD"        2026-10-14 2026-10-13
l1 "empty json"       ""             2026-10-11 2026-10-13
l1 "rows not array"   '{"rows":{}}'  2026-10-11 2026-10-13
l1 "top-level array"  '[1]'          2026-10-11 2026-10-13
l1 "not json"         'not json'     2026-10-11 2026-10-13

# L2: buckets
J='{"rows":[
 {"mode":"full","completed_at":"2026-10-13T01:00:00Z"},
 {"mode":"full","completed_at":"2026-10-13T02:00:00Z"},
 {"mode":"batch-selected","completed_at":"2026-10-13T03:00:00Z"},
 {"mode":"full-legacy","completed_at":"2026-10-13T04:00:00Z"},
 {"mode":null,"completed_at":"2026-10-13T05:00:00Z"}],"truncated":false}'
OUT=$(ev "$J" 2026-10-13 2026-10-13); RC=$?
{ [ "$RC" = 0 ] && [[ $OUT == *"2026-10-13 full 2 selected 1 other 2"* ]]; } \
  && ok || bad "L2 buckets: rc $RC out='$OUT'"

# L3: window edges
J='{"rows":[
 {"mode":"full","completed_at":"2026-10-11T00:00:00Z"},
 {"mode":"full","completed_at":"2026-10-10T23:59:59Z"},
 {"mode":"full","completed_at":"2026-10-14T00:00:01Z"},
 {"mode":"full","completed_at":null}],"truncated":false}'
OUT=$(ev "$J" 2026-10-11 2026-10-13); RC=$?
{ [ "$RC" = 0 ] && [[ $OUT == *"2026-10-11 full 1 selected 0 other 0"* ]] \
  && [[ $OUT == *"total full 1 selected 0 other 0" ]] && [[ $OUT != *2026-10-10* ]] && [[ $OUT != *2026-10-14* ]]; } \
  && ok || bad "L3 window edges: rc $RC out='$OUT'"

# L4: a quiet day prints zeros; oldest first
J='{"rows":[
 {"mode":"full","completed_at":"2026-10-11T08:00:00Z"},
 {"mode":"batch-selected","completed_at":"2026-10-13T08:00:00Z"}],"truncated":false}'
OUT=$(ev "$J" 2026-10-11 2026-10-13); RC=$?
WANT="2026-10-11 full 1 selected 0 other 0  2026-10-12 full 0 selected 0 other 0  2026-10-13 full 0 selected 1 other 0  total full 1 selected 1 other 0"
{ [ "$RC" = 0 ] && [ "$OUT" = "$WANT" ]; } && ok || bad "L4 quiet day / order: rc $RC out='$OUT'"

# L5: truncated -> rc 2, no output
J='{"rows":[{"mode":"full","completed_at":"2026-10-13T08:00:00Z"}],"truncated":true}'
OUT=$(ev "$J" 2026-10-11 2026-10-13); RC=$?
{ [ "$RC" = 2 ] && [ -z "$OUT" ]; } && ok || bad "L5 truncated: want rc 2 and no output, got rc $RC out='$OUT'"

# L6: no rows -> every day zeros
OUT=$(ev '{"rows":[]}' 2026-10-12 2026-10-13); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "2026-10-12 full 0 selected 0 other 0  2026-10-13 full 0 selected 0 other 0  total full 0 selected 0 other 0" ]; } \
  && ok || bad "L6 empty rows: rc $RC out='$OUT'"

# ── Block ────────────────────────────────────────────────────────────────────
# B0: the block extracts
awk '/^# >>> ci batch modes/{f=1;next} /^# <<< ci batch modes/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "B0 could not extract the ci-batch-modes block — markers missing?"

NOWS=1791892800   # 2026-10-13T12:00:00Z
: > "$T/alerts.txt"
# drive [nojobs] — env knobs pass through from the caller
drive() {
  : > "$T/logs/pipeline-health.log"; : > "$T/req.txt"
  ( export H="$T" T="$T" NOW="$NOWS" NOJOBS="${1:-}"
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      alert()        { echo "alert $*"        >> "$T/alerts.txt"; }
      alert_digest() { echo "alert_digest $*" >> "$T/alerts.txt"; }
      alert_emit()   { echo "alert_emit $*"   >> "$T/alerts.txt"; }
      if [ -z "$NOJOBS" ]; then
        _jobs_req() { echo "$*" >> "$T/req.txt"; cat "$T/answer.json"; return "$(cat "$T/answer.rc" 2>/dev/null || echo 0)"; }
      fi
      . "$0"' "$T/blk.sh" 2>"$T/err.txt" )
}
LOG="$T/logs/pipeline-health.log"
SF="$T/state/ci-batch-modes.stamp"
answer() { printf '%s' "$1" > "$T/answer.json"; echo "${2:-0}" > "$T/answer.rc"; }
nlines() { grep -c . "$LOG"; }

# B1: counts
answer '{"rows":[
 {"repo":"o/r","mode":"full","completed_at":"2026-10-12T01:00:00Z"},
 {"repo":"o/r","mode":"full","completed_at":"2026-10-12T02:00:00Z"},
 {"repo":"o/r","mode":"full","completed_at":"2026-10-12T03:00:00Z"},
 {"repo":"o/r","mode":"batch-selected","completed_at":"2026-10-12T04:00:00Z"},
 {"repo":"o/r","mode":"full","completed_at":"2026-10-13T01:00:00Z"},
 {"repo":"o/r","mode":"batch-selected","completed_at":"2026-10-13T02:00:00Z"},
 {"repo":"o/r","mode":"batch-selected","completed_at":"2026-10-13T03:00:00Z"}],"truncated":false}'
rm -f "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=0 drive
L=$(cat "$LOG")
{ [ "$(nlines)" = 1 ] \
  && [[ $L == "TS ci batch modes 3d (merge-queue batches per UTC day of completed_at): 2026-10-11 full 0 selected 0 other 0"* ]] \
  && [[ $L == *"2026-10-12 full 3 selected 1 other 0"* ]] && [[ $L == *"2026-10-13 full 1 selected 2 other 0"* ]] \
  && [[ $L == *"total full 4 selected 3 other 0" ]]; } \
  && ok || bad "B1 count line: '$L' err=$(cat "$T/err.txt")"

# B2: truncated -> unknown, no counts
answer '{"rows":[{"mode":"full","completed_at":"2026-10-13T01:00:00Z"}],"truncated":true}'
rm -f "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=0 drive
{ [ "$(nlines)" = 1 ] && [ "$(cat "$LOG")" = "TS ci batch modes 3d: unknown (answer truncated)" ] && ! grep -q 'total full' "$LOG"; } \
  && ok || bad "B2 truncated: '$(cat "$LOG")'"

# B3: not json
answer 'not json'
rm -f "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=0 drive
[ "$(cat "$LOG")" = "TS ci batch modes 3d: unknown (answer not a ci-batches list)" ] \
  && ok || bad "B3 not json: '$(cat "$LOG")'"

# B4: defaults (knobs unset): since 2026-10-07, 7 day groups
answer '{"rows":[],"truncated":false}'
rm -f "$SF"; ( unset CI_BATCH_MODES_DAYS CI_BATCH_MODES_EVERY; drive )
L=$(cat "$LOG")
{ [ "$(cat "$T/req.txt")" = "GET /api/ci-batches?since=2026-10-07&limit=5000" ] \
  && [[ $L == "TS ci batch modes 7d (merge-queue batches per UTC day of completed_at): 2026-10-07 full 0"* ]] \
  && [ "$(grep -o '2026-10-[0-9][0-9] full' "$LOG" | sort -u | wc -l)" = 7 ] \
  && [[ $L == *"2026-10-13 full 0 selected 0 other 0  total full 0 selected 0 other 0" ]]; } \
  && ok || bad "B4 defaults: req='$(cat "$T/req.txt")' line='$L'"

# B5: worker down -> unknown, stamp = NOW
answer '' 1
rm -f "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=0 drive
{ [ "$(cat "$LOG")" = "TS ci batch modes 3d: unknown (no answer from GET /api/ci-batches)" ] && [ "$(cat "$SF" 2>/dev/null)" = "$NOWS" ]; } \
  && ok || bad "B5 worker down: '$(cat "$LOG")' stamp=$(cat "$SF" 2>/dev/null)"

# B6: cadence
answer '{"rows":[],"truncated":false}'
echo $((NOWS - 600)) > "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=3600 drive
{ [ ! -s "$LOG" ] && [ ! -s "$T/req.txt" ] && [ "$(cat "$SF")" = $((NOWS - 600)) ]; } \
  && ok || bad "B6 stamp 600s old must skip: log='$(cat "$LOG")' req='$(cat "$T/req.txt")' stamp=$(cat "$SF")"
echo $((NOWS - 3600)) > "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=3600 drive
{ [ "$(nlines)" = 1 ] && [ "$(cat "$SF")" = "$NOWS" ]; } \
  && ok || bad "B6 stamp 3600s old must run: log='$(cat "$LOG")' stamp=$(cat "$SF")"

# B9: bad knob values fall back
for v in 31 0 abc; do
  rm -f "$SF"; CI_BATCH_MODES_DAYS=$v CI_BATCH_MODES_EVERY=0 drive
  [ "$(cat "$T/req.txt")" = "GET /api/ci-batches?since=2026-10-07&limit=5000" ] \
    && ok || bad "B9 CI_BATCH_MODES_DAYS=$v must fall back to 7: req='$(cat "$T/req.txt")'"
done
echo $((NOWS - 600)) > "$SF"; CI_BATCH_MODES_DAYS=3 CI_BATCH_MODES_EVERY=abc drive
{ [ ! -s "$LOG" ] && [ ! -s "$T/req.txt" ]; } \
  && ok || bad "B9 CI_BATCH_MODES_EVERY=abc must fall back to 3600: log='$(cat "$LOG")'"

# B7: no alert, digest or emit in any drive above
[ -s "$T/alerts.txt" ] && bad "B7 a measurement never pages: $(cat "$T/alerts.txt")" || ok

# B8: no client, or no lib -> no line, no stamp
rm -f "$SF"; CI_BATCH_MODES_EVERY=0 drive nojobs
{ [ ! -s "$LOG" ] && [ ! -e "$SF" ]; } && ok || bad "B8 no _jobs_req: log='$(cat "$LOG")' stamp exists=$([ -e "$SF" ] && echo y)"
mv "$T/bin/lib/ci-batch-modes.sh" "$T/lib.bak" 2>/dev/null
rm -f "$SF"; CI_BATCH_MODES_EVERY=0 drive
{ [ ! -s "$LOG" ] && [ ! -e "$SF" ] && [ ! -s "$T/req.txt" ]; } && ok || bad "B8 no lib: log='$(cat "$LOG")' stamp exists=$([ -e "$SF" ] && echo y)"

echo "pipeline-health-ci-batch-modes: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
