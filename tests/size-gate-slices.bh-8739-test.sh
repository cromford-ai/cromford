#!/bin/bash
# tests/size-gate-slices.bh-8739-test.sh — BH-8739: bin/size-gate.sh reports
# how many slices it expects (SIZE_SLICES_EXPECTED), so the decomposer can ask a
# person before it files more than SLICE_CONFIRM_OVER children.
#
#   n = max(1, ceil(LINES / max-lines), ceil(FILES / max-files)), on the
#   declared path and on the estimated path; no line when no plan is readable.
#
# Drives the real script on scratch plans. No network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/size-gate-slices.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/size-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

plan() { # plan <files> <lines> — a plan with a declared ## Size
  printf '# Plan\n\n## Size\n\nFILES: %s\nLINES: %s\n' "$1" "$2" > "$T/plan.md"
}
expected() { # expected <plan> [list] — the SIZE_SLICES_EXPECTED value, or "none"
  local out v
  out=$("$GATE" "$1" 700 20 ${2:+"$2"} 2>&1)
  v=$(sed -n 's/^SIZE_SLICES_EXPECTED:[[:space:]]*//p' <<<"$out" | tail -1)
  printf '%s' "${v:-none}"
}

plan 5 400;   v=$(expected "$T/plan.md"); [ "$v" = 1 ] && ok || bad "400 lines / 5 files at 700/20 -> 1, got $v"
plan 8 1500;  v=$(expected "$T/plan.md"); [ "$v" = 3 ] && ok || bad "1500 lines / 8 files -> 3, got $v"
plan 10 4000; v=$(expected "$T/plan.md"); [ "$v" = 6 ] && ok || bad "4000 lines / 10 files -> 6, got $v"
plan 45 300;  v=$(expected "$T/plan.md"); [ "$v" = 3 ] && ok || bad "300 lines / 45 files -> 3 (the files axis), got $v"
plan 20 700;  v=$(expected "$T/plan.md"); [ "$v" = 1 ] && ok || bad "exactly at the limits -> 1, got $v"
plan 20 701;  v=$(expected "$T/plan.md"); [ "$v" = 2 ] && ok || bad "one line over -> 2, got $v"
# The verdict lines are unchanged next to the new one.
plan 10 4000; out=$("$GATE" "$T/plan.md" 700 20 2>&1); rc=$?
[ "$rc" = 2 ] && ok || bad "an over plan still exits 2, got $rc"
grep -q '^SIZE_VERDICT: over$' <<<"$out" && ok || bad "an over plan still says SIZE_VERDICT: over: $out"

# Estimated path: no ## Size, 50 product files in the list -> lines 1750.
printf '# Plan\n\nno size here\n' > "$T/nosize.md"
: > "$T/list.txt"; i=1
while [ "$i" -le 50 ]; do printf 'src/mod%s.ts\n' "$i" >> "$T/list.txt"; i=$((i + 1)); done
v=$(expected "$T/nosize.md" "$T/list.txt")
[ "$v" = 3 ] && ok || bad "estimated 50 files / 1750 lines -> 3, got $v"
# Estimated with no list: 0 files -> 1.
v=$(expected "$T/nosize.md"); [ "$v" = 1 ] && ok || bad "an estimate from no list -> 1, got $v"

# No readable plan: undeclared prints no slice count.
: > "$T/empty.md"
v=$(expected "$T/empty.md"); [ "$v" = none ] && ok || bad "an empty plan prints no SIZE_SLICES_EXPECTED, got $v"

echo "size-gate-slices.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
