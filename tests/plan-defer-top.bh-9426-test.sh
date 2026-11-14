#!/bin/bash
# tests/plan-defer-top.bh-9426-test.sh — the planner prompt carries the current
# top deferral files as "files to stay out of unless the ticket is about them",
# read from bin/defer-report.sh's output file, never hardcoded (BH-9426 scope 4).
#
#   D1  round trip: bin/defer-report.sh --out on fixture build dirs, then
#       defer_top_line, prints the same paths in the same order
#   D2  absent file, empty file -> nothing
#   D3  a file older than DEFER_TOP_MAX_AGE_H (default 48) -> nothing; a knob of
#       72 shows it again
#   D4  the `# >>> defer top` block of bin/lib/rb/plan.sh appends the line to
#       VMAP_ORIENT (the text CC() puts in front of the plan prompt); with no
#       report the block leaves VMAP_ORIENT as it was
#   M1  a plan.sh block without the defer_top_line call leaves the prompt bare
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/builds" "$H/logs" "$H/state/defer-report"
scratch_install_closure bin/defer-report.sh "$H" >/dev/null || bad "closure install: bin/defer-report.sh"
scratch_install_closure bin/lib/defer-top.sh "$H" >/dev/null || bad "closure install: bin/lib/defer-top.sh"
NOW=$(date -u -d '2026-11-12 12:00:00' +%s)
B="$H/builds"
mkdir -p "$B/acme-AB-1-202611120900" "$B/acme-AB-3-202611121000"
echo "BUILD_DEFERRED OVERLAP_DEFER AB-1 vs AB-2 files=[src/pay.ts,src/pay.ts,lib/x.sh,lib/x.sh]; not before 2026-11-12 09:10:00Z" > "$B/acme-AB-1-202611120900/RESULT"
echo "BUILD_DEFERRED OVERLAP_DEFER AB-3 vs AB-2 files=[src/pay.ts,src/pay.ts]; not before 2026-11-12 10:10:00Z" > "$B/acme-AB-3-202611121000/RESULT"
TOP="$H/state/defer-report/acme-top.txt"

dtl() { # dtl [env...] -> the line, with the clock pinned
  env HARNESS="$H" DEFER_TOP_NOW="$NOW" "$@" bash -c '. "$1/bin/lib/defer-top.sh" || exit 90; defer_top_line acme "$1"' _ "$H"
}

# D1 round trip
LANE_GATE_DISABLE=1 HARNESS="$H" bash "$H/bin/defer-report.sh" --builds "$B" --now "$NOW" --project acme --last 7d --out "$TOP" >/dev/null 2>&1 \
  || bad "D1: defer-report.sh --out failed"
touch -d '2026-11-12 11:00:00 UTC' "$TOP"
L=$(dtl)
case "$L" in
  "FILES TO STAY OUT OF UNLESS THE TICKET IS ABOUT THEM (top 2 deferral files, from bin/defer-report.sh at 2026-11-12T11:00:00Z): src/pay.ts, lib/x.sh") ok ;;
  *) bad "D1: wrong line: [$L]" ;;
esac
# D2 absent and empty
mv "$TOP" "$T/top.keep"
[ -z "$(dtl)" ] && ok || bad "D2: an absent report must print nothing"
: > "$TOP"; touch -d '2026-11-12 11:00:00 UTC' "$TOP"
[ -z "$(dtl)" ] && ok || bad "D2: an empty report must print nothing"
mv "$T/top.keep" "$TOP"
# D3 age
touch -d '2026-11-10 11:00:00 UTC' "$TOP"   # 49 h before NOW
[ -z "$(dtl)" ] && ok || bad "D3: a report 49 h old must print nothing with DEFER_TOP_MAX_AGE_H unset (default 48)"
[ -n "$(dtl DEFER_TOP_MAX_AGE_H=72)" ] && ok || bad "D3: DEFER_TOP_MAX_AGE_H=72 must show a 49 h old report"
touch -d '2026-11-12 11:00:00 UTC' "$TOP"
# no root -> nothing, rc != 0, never a /root/harness default (D43)
DTL_LIB="$H/bin/lib/defer-top.sh"
(unset HARNESS H; . "$DTL_LIB"; defer_top_line acme "") && bad "D3: an empty root must refuse" || ok
grep -q '/root/harness' "$DIR/bin/lib/defer-top.sh" && bad "D3: bin/lib/defer-top.sh must not name /root/harness" || ok

# D4 the plan.sh block
blk() { awk '/^# >>> defer top/{f=1;next} /^# <<< defer top/{exit} f' "$1" > "$2"; }
blk "$DIR/bin/lib/rb/plan.sh" "$T/blk.sh"
[ -s "$T/blk.sh" ] || bad "D4: bin/lib/rb/plan.sh has no '# >>> defer top' block"
mkdir -p "$T/build"
runblk() { # runblk <block> -> the VMAP_ORIENT after the block
  env HARNESS="$H" DEFER_TOP_NOW="$NOW" bash -c '
    PROJECT=acme KEY=AB-9 BUILD="$2"; STAMP() { echo stamp; }
    VMAP_ORIENT="VERIFICATION MAP AVAILABLE (fixture)"
    . "$1"; printf "%s" "$VMAP_ORIENT"' _ "$1" "$T/build"
}
V=$(runblk "$T/blk.sh")
[ "$(head -1 <<<"$V")" = "VERIFICATION MAP AVAILABLE (fixture)" ] && ok || bad "D4: the map line must stay first: [$V]"
grep -qxF "$L" <<<"$V" && ok || bad "D4: the plan prompt orientation must carry the defer line: [$V]"
mv "$TOP" "$T/top.keep"
V=$(runblk "$T/blk.sh")
[ "$V" = "VERIFICATION MAP AVAILABLE (fixture)" ] && ok || bad "D4: no report must leave VMAP_ORIENT unchanged: [$V]"
mv "$T/top.keep" "$TOP"

# M1 the call removed -> D4 red
sed '/defer_top_line/d' "$T/blk.sh" > "$T/blk-m1.sh"
cmp -s "$T/blk-m1.sh" "$T/blk.sh" && bad "M1: the mutant changed nothing"
V=$(runblk "$T/blk-m1.sh" 2>/dev/null)
grep -qxF "$L" <<<"$V" && bad "M1: a block without defer_top_line must not carry the line" || ok

echo "plan-defer-top.bh-9426: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
