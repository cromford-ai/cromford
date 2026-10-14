#!/bin/bash
# tests/gh-ledger-report.bh-4477-test.sh — BH-4477 C0: bin/gh-ledger-report.sh,
# the caller × endpoint-shape view of this box's GitHub REST ledger.
#
# WHY. the operator's 2026-10-04 diagnosis of the hub's gh api volume was done by hand
# over state/gh-rest-ledger/2026-10-04T19.tsv. The done-when of #4477 is a
# before/after reading from this script, so what it counts has to be pinned:
# rows grouped by caller AND endpoint shape (ids collapsed), sorted by calls
# with a stable tie-break, counted vs uncounted (304/000) kept apart, the
# window honoured across hour files, and no API call made to produce it.
#
# Drives the real script against fixture ledger files in the writer's own
# 14-column shape (bin/lib/gh-rest-ledger.sh gh_ledger_append), with
# GH_LEDGER_REPORT_NOW fixing the clock.
# Run from anywhere: tests/gh-ledger-report.bh-4477-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPORT="$DIR/bin/gh-ledger-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -x "$REPORT" ] || { echo "FAIL: $REPORT missing or not executable"; exit 1; }

# A fake gh on PATH that records any call: the report must never make one.
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.txt"\nexit 0\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
unset HARNESS H

NOW=$(date -u -d '2026-10-04T19:30:00Z' +%s)
export GH_LEDGER_REPORT_NOW="$NOW"

# row <dir> <ts> <caller> <method> <path> <status> <counted> — one writer-shaped line
row() {
  local h=${2%%:*}
  printf '%s\t%s\tcromford\t%s\t%s\t%s\t%s\t4000\t1791147755\tapp-1\tcore\trest\t100\t6600\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >> "$1/$h.tsv"
}
rows() { local n=$1; shift; local i; for i in $(seq 1 "$n"); do row "$@"; done; }

run() { OUT=$("$REPORT" "$@" 2>&1); RC=$?; }
ranked() { printf '%s\n' "$OUT" | awk '$1 ~ /^[0-9]+$/'; }

# ---- 1. grouping by caller × endpoint shape, sorted by calls ----------------
D1="$T/l1"; mkdir -p "$D1"
rows 3 "$D1" 2026-10-04T19:20:00Z stuck-work.sh GET repos/F/R/issues/N/comments 200 1
rows 5 "$D1" 2026-10-04T19:10:00Z merge-conductor.sh GET repos/F/R/pulls/N 200 1
run --last 1h --dir "$D1"
[ "$RC" = 0 ] && ok || bad "1: rc $RC: $OUT"
first=$(ranked | sed -n 1p); second=$(ranked | sed -n 2p)
case "$first" in *" 5 "*merge-conductor.sh*"GET repos/F/R/pulls/N") ok ;; *) bad "1: rank 1 should be merge-conductor pulls/N x5, got [$first]" ;; esac
case "$second" in *" 3 "*stuck-work.sh*"GET repos/F/R/issues/N/comments") ok ;; *) bad "1: rank 2 should be stuck-work comments x3, got [$second]" ;; esac
[ "$(ranked | wc -l)" = 2 ] && ok || bad "1: expected 2 ranked rows, got $(ranked | wc -l)"
grep -q '^TOTAL  calls=8  counted=8  uncounted=0  per_hour=8$' <<<"$OUT" && ok || bad "1: TOTAL line wrong: $OUT"
grep -q '^gh-ledger-report: .* window 2026-10-04T18:30:00Z..2026-10-04T19:30:00Z (1h) — 1 hour file(s)$' <<<"$OUT" \
  && ok || bad "1: header wrong: $(head -1 <<<"$OUT")"

# ---- 2. id collapse: raw ids fold into N, a 40-hex sha into SHA -------------
D2="$T/l2"; mkdir -p "$D2"
rows 2 "$D2" 2026-10-04T19:10:00Z merge-conductor.sh GET repos/F/R/pulls/N 200 1
row "$D2" 2026-10-04T19:11:00Z merge-conductor.sh GET repos/F/R/pulls/4060 200 1
row "$D2" 2026-10-04T19:12:00Z ci.sh GET repos/F/R/commits/SHA/status 200 1
row "$D2" 2026-10-04T19:13:00Z ci.sh GET repos/F/R/commits/0123456789abcdef0123456789abcdef01234567/status 200 1
run --last 1h --dir "$D2"
ranked | grep -q ' 3 .*merge-conductor.sh  *GET repos/F/R/pulls/N$' && ok || bad "2: pulls/4060 did not group with pulls/N: $OUT"
ranked | grep -q ' 2 .*ci.sh  *GET repos/F/R/commits/SHA/status$' && ok || bad "2: SHA rows did not group as SHA: $OUT"
grep -q '4060\|0123456789' <<<"$(ranked)" && bad "2: a raw id survived: $OUT" || ok

# ---- 3. tie-break by caller then endpoint; byte-identical reruns -------------
D3="$T/l3"; mkdir -p "$D3"
rows 2 "$D3" 2026-10-04T19:05:00Z zeta.sh GET repos/F/R/pulls 200 1
rows 2 "$D3" 2026-10-04T19:06:00Z alpha.sh GET repos/F/R/pulls/N 200 1
rows 2 "$D3" 2026-10-04T19:07:00Z alpha.sh GET repos/F/R/issues 200 1
rows 4 "$D3" 2026-10-04T19:08:00Z mid.sh GET repos/F/R/branches 200 1
run --last 1h --dir "$D3"; A="$OUT"
order=$(ranked | awk '{print $5" "$7}' | tr '\n' '|')
[ "$order" = "mid.sh repos/F/R/branches|alpha.sh repos/F/R/issues|alpha.sh repos/F/R/pulls/N|zeta.sh repos/F/R/pulls|" ] \
  && ok || bad "3: order wrong: $order"
run --last 1h --dir "$D3"
[ "$A" = "$OUT" ] && ok || bad "3: two runs differ"

# ---- 4. --top 2 prints 2 rows; TOTAL still sums everything ------------------
run --last 1h --top 2 --dir "$D3"
[ "$(ranked | wc -l)" = 2 ] && ok || bad "4: --top 2 printed $(ranked | wc -l) rows"
grep -q '^TOTAL  calls=10 ' <<<"$OUT" && ok || bad "4: TOTAL should still be 10: $OUT"
run --last 1h --top 0 --dir "$D3"
[ "$(ranked | wc -l)" = 4 ] && ok || bad "4: --top 0 should print all 4, got $(ranked | wc -l)"

# ---- 5. window: 61 min old is out of 1h and in 2h; hour files spanned -------
D5="$T/l5"; mkdir -p "$D5"
row "$D5" 2026-10-04T18:29:00Z old.sh GET repos/F/R/pulls 200 1
row "$D5" 2026-10-04T18:45:00Z prev-hour.sh GET repos/F/R/pulls 200 1
row "$D5" 2026-10-04T19:15:00Z this-hour.sh GET repos/F/R/pulls 200 1
run --last 1h --dir "$D5"
grep -q 'old.sh' <<<"$OUT" && bad "5: a 61-min-old row is in --last 1h" || ok
ranked | grep -q 'prev-hour.sh' && ranked | grep -q 'this-hour.sh' && ok || bad "5: --last 1h did not read both hour files: $OUT"
grep -q '— 2 hour file(s)$' <<<"$OUT" && ok || bad "5: header should name 2 files: $(head -1 <<<"$OUT")"
run --last 2h --dir "$D5"
ranked | grep -q 'old.sh' && ok || bad "5: --last 2h dropped the 61-min-old row: $OUT"
run --last 20m --dir "$D5"
[ "$(ranked | wc -l)" = 1 ] && ranked | grep -q this-hour.sh && ok || bad "5: --last 20m should keep only this-hour.sh: $OUT"

# ---- 6. counted / uncounted -------------------------------------------------
D6="$T/l6"; mkdir -p "$D6"
rows 2 "$D6" 2026-10-04T19:10:00Z etag.sh GET repos/F/R/pulls 200 1
row "$D6" 2026-10-04T19:11:00Z etag.sh GET repos/F/R/pulls 304 0
row "$D6" 2026-10-04T19:12:00Z etag.sh GET repos/F/R/pulls 000 0
run --last 1h --dir "$D6"
ranked | awk '{print $2,$3,$4}' | grep -qx '4 2 2' && ok || bad "6: calls/counted/uncounted should be 4 2 2: $OUT"
grep -q '^TOTAL  calls=4  counted=2  uncounted=2 ' <<<"$OUT" && ok || bad "6: TOTAL counted wrong: $OUT"

# ---- 7. no API call ---------------------------------------------------------
[ ! -s "$T/gh-calls.txt" ] && ok || bad "7: the report called gh: $(cat "$T/gh-calls.txt")"

# ---- 8. errors and the empty window -----------------------------------------
run --last 1h --dir "$T/nope"
[ "$RC" = 2 ] && ok || bad "8: missing dir should be rc 2, got $RC"
grep -q 'calls=0' <<<"$OUT" && bad "8: missing dir printed a zero TOTAL" || ok
grep -q "$T/nope" <<<"$OUT" && ok || bad "8: missing dir message should name it: $OUT"
for a in abc 0h -1 5d 1.5h ''; do
  run --last "$a" --dir "$D1"
  [ "$RC" = 2 ] && ok || bad "8: --last '$a' should be rc 2, got $RC"
done
for a in abc -1 1x; do
  run --top "$a" --dir "$D1"
  [ "$RC" = 2 ] && ok || bad "8: --top '$a' should be rc 2, got $RC"
done
run --bogus --dir "$D1"
[ "$RC" = 2 ] && ok || bad "8: unknown arg should be rc 2, got $RC"
GH_LEDGER_REPORT_NOW=yesterday run --dir "$D1"
[ "$RC" = 2 ] && ok || bad "8: a non-numeric GH_LEDGER_REPORT_NOW should be rc 2, got $RC"
D8="$T/l8"; mkdir -p "$D8"
run --last 1h --dir "$D8"
[ "$RC" = 0 ] && ok || bad "8: empty window should be rc 0, got $RC"
grep -qx 'no ledger rows in window' <<<"$OUT" && ok || bad "8: empty window line missing: $OUT"
grep -q '^TOTAL' <<<"$OUT" && bad "8: empty window printed a TOTAL" || ok
run -h
[ "$RC" = 0 ] && grep -q -- '--last' <<<"$OUT" && ok || bad "8: -h should print usage rc 0"

# ---- 9. a torn row is skipped -----------------------------------------------
D9="$T/l9"; mkdir -p "$D9"
row "$D9" 2026-10-04T19:10:00Z whole.sh GET repos/F/R/pulls 200 1
printf '2026-10-04T19:11:00Z\ttorn.sh\tcromford\tGET\trepos/F/R/pulls\n' >> "$D9/2026-10-04T19.tsv"
run --last 1h --dir "$D9"
grep -q torn.sh <<<"$OUT" && bad "9: a 5-column row was counted: $OUT" || ok
grep -q '^TOTAL  calls=1 ' <<<"$OUT" && ok || bad "9: TOTAL should be 1: $OUT"

# ---- 10. the default dir is $HARNESS/state/gh-rest-ledger -------------------
mkdir -p "$T/h/state"; cp -R "$D1" "$T/h/state/gh-rest-ledger"
OUT=$(HARNESS="$T/h" "$REPORT" --last 1h 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^TOTAL  calls=8 ' <<<"$OUT" && ok || bad "10: default dir not read: rc $RC $OUT"

[ ! -s "$T/gh-calls.txt" ] && ok || bad "end: the report called gh: $(cat "$T/gh-calls.txt")"
echo "gh-ledger-report.bh-4477: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
