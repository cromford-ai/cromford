#!/bin/bash
# tests/size-gate-diff-kb.bh-5803-test.sh — the plan declares its whole diff in
# kilobytes (`DIFF_KB:` in `## Size`), and bin/size-gate.sh sends a plan over
# the lead review's diff limit (LEAD_REVIEW_DIFF_MAX_BYTES, 400000 by default)
# to the decomposer, the same as a plan over the line limit.
#   S1  DIFF_KB 120: exit 0, SIZE_DIFF_KB and SIZE_DIFF_LIMIT_KB printed
#   S2  DIFF_KB 900: exit 2, SIZE_OVER names diff_kb=900>400, verdict over
#   S3  no DIFF_KB line: the output is byte-identical to the gate before this axis
#   S4  DIFF_KB 450: inside the 15% band, exit 0, SIZE_TOLERATED names it
#   S5  LEAD_REVIEW_DIFF_MAX_BYTES=600000 -> limit 600; =abc -> limit 400
#   S6  the plan prompt asks for DIFF_KB and no longer says "Two lines"
#   M3  mutation: the gate without the diff axis makes S2 red
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/size-gate-diff-kb.bh-5803-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
GATE="$SRC/bin/size-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/size-gate.sh does not exist"; exit 1; }
unset LEAD_REVIEW_DIFF_MAX_BYTES SIZE_GATE_TOLERANCE_PCT SIZE_LIMITS_SRC

plan() { # plan <file> [diff-kb]
  { printf '# plan\n\n## Size\n\nFILES: 4\nLINES: 200\n'
    [ -n "${2:-}" ] && printf 'DIFF_KB: %s\n' "$2"
    printf '\nSIZE: M\n'; } > "$1"
}
run() { # run <gate> <plan> — OUT and RC
  OUT=$(bash "$1" "$2" 700 20 2>&1); RC=$?
}

# ── S1 ──
plan "$T/s1.md" 120; run "$GATE" "$T/s1.md"
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC out=$OUT"
grep -qx 'SIZE_DIFF_KB: 120' <<<"$OUT" && grep -qx 'SIZE_DIFF_LIMIT_KB: 400' <<<"$OUT" && ok || bad "S1 out=$OUT"
grep -qx 'SIZE_VERDICT: within' <<<"$OUT" && ok || bad "S1 verdict: $OUT"

# ── S2 ──
plan "$T/s2.md" 900; run "$GATE" "$T/s2.md"
[ "$RC" = 2 ] && ok || bad "S2 rc=$RC out=$OUT"
grep -q '^SIZE_OVER: .*diff_kb=900>400' <<<"$OUT" && ok || bad "S2 SIZE_OVER: $OUT"
grep -qx 'SIZE_VERDICT: over' <<<"$OUT" && ok || bad "S2 verdict: $OUT"

# ── S3: no DIFF_KB = the output the gate printed before this axis, byte for byte ──
plan "$T/s3.md"; run "$GATE" "$T/s3.md"
printf '%s\n' 'SIZE_DECLARED: files=4 lines=200' 'SIZE_FILES: 4' 'SIZE_LINES: 200' 'SIZE_LIMITS: lines=700 files=20' \
  'SIZE_TOLERANCE: 15% (lines<=805 files<=23 build whole)' 'SIZE_VERDICT: within' > "$T/s3.want"
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | cmp -s - "$T/s3.want" && ok || bad "S3 rc=$RC out=[$OUT]"

# ── S4: inside the band ──
plan "$T/s4.md" 450; run "$GATE" "$T/s4.md"
[ "$RC" = 0 ] && ok || bad "S4 rc=$RC out=$OUT"
grep -q '^SIZE_TOLERATED: .*diff_kb=450>400' <<<"$OUT" && ok || bad "S4 SIZE_TOLERATED: $OUT"

# ── S5: the limit follows the review knob ──
plan "$T/s5.md" 500
OUT=$(LEAD_REVIEW_DIFF_MAX_BYTES=600000 bash "$GATE" "$T/s5.md" 700 20 2>&1); RC=$?
[ "$RC" = 0 ] && grep -qx 'SIZE_DIFF_LIMIT_KB: 600' <<<"$OUT" && ok || bad "S5 600000: rc=$RC out=$OUT"
plan "$T/s5b.md" 900
OUT=$(LEAD_REVIEW_DIFF_MAX_BYTES=abc bash "$GATE" "$T/s5b.md" 700 20 2>&1); RC=$?
[ "$RC" = 2 ] && grep -qx 'SIZE_DIFF_LIMIT_KB: 400' <<<"$OUT" && ok || bad "S5 abc: rc=$RC out=$OUT"

# ── S6: the planning prompt asks for it ──
# TEST-CHANGE (BH-7970): the plan prompt prose moved to prompts/stages/plan.md.
PP="$SRC/prompts/stages/plan.md"
if [ -f "$PP" ]; then
  [ "$(grep -c "DIFF_KB: <n>" "$PP")" -ge 1 ] && ok || bad "S6 the plan prompt does not ask for 'DIFF_KB: <n>'"
  [ "$(grep -c 'Two lines, exactly these keys' "$PP")" = 0 ] && ok || bad "S6 the plan prompt still says 'Two lines'"
else
  bad "S6 prompts/stages/plan.md does not exist"
fi

# ── M3: no diff axis -> S2 red ──
sed '/diff_kb=/d' "$GATE" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$GATE"; then bad "M3 mutation anchor missing"
else
  run "$T/mut.sh" "$T/s2.md"
  [ "$RC" = 2 ] && grep -q 'diff_kb=900>400' <<<"$OUT" && bad "M3 S2 stayed green without the diff axis" || ok
fi

echo "size-gate-diff-kb.bh-5803: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
