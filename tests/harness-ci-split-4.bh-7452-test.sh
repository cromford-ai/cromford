#!/bin/bash
# tests/harness-ci-split-4.bh-7452-test.sh — BH-7540 (5 of 5, split from BH-7452):
# the decisions, ci-timings, harness-safety, main-ci and prompt-evals jobs in
# config/harness-ci/ are a header fragment (000-job.yml) plus one
# NNN-<slug>.yml fragment per step.
#
#   P1 the render of the committed fragments cmp-equals the committed workflow,
#      and --check is clean with no stdout.
#   P2 per job dir: the step-file count equals the job's step count in the
#      render (>= 1: main-ci has one step); 000-job.yml holds no step line, starts `  <job>:` and ends
#      `    steps:`; each step file holds exactly one step line.
#   P3 per job dir: a scratch 015-probe.yml renders right after the 010
#      fragment and right before the 020 fragment (main-ci has no 020: right
#      before the next job header, `  prompt-evals:`); --check on it is rc 1.
#   N1 a scratch 016-Probe.yml (capital) is refused rc 3.
#
# The share mirror has no config/harness-ci/: the suite SKIPs there, rc 0.
# No network, no clock: scratch trees under $T only.
#   HARNESS_TEST_SANDBOX=1 bash tests/harness-ci-split-4.bh-7452-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RCW="$DIR/bin/render-ci-workflow.sh"
WFP=.github/workflows/harness-ci.yml
SRC=config/harness-ci
JOBS="170-decisions:decisions 180-ci-timings:ci-timings 190-harness-safety:harness-safety 200-main-ci:main-ci 210-prompt-evals:prompt-evals"
# main-ci is one step: after it comes the next job header, not a 020 fragment.
NEXT_JOB_AFTER_MAIN_CI="  prompt-evals:"

if [ ! -x "$RCW" ] || [ ! -d "$DIR/$SRC" ]; then
  echo "SKIP harness-ci-split-4.bh-7452: no config/harness-ci in this copy"
  exit 0
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

STEP='^      - '
# seed <root>: a scratch root with the committed fragments and render.
seed() {
  scratch_rm "$1"; mkdir -p "$1/.github/workflows" "$1/config"
  cp -R "$DIR/$SRC" "$1/$SRC"
  cp "$DIR/$WFP" "$1/$WFP"
}
# steps_in <dir>: the step fragments of a job dir, one name per line.
steps_in() { (cd "$1" && ls -1 | grep -E '^[0-9]{3}-[a-z0-9-]+\.yml$' | grep -vx '000-job.yml'); }
# render_steps <render> <job>: the step lines of one job in a render.
render_steps() {
  awk -v j="  $2:" '$0 == j { on = 1; next } on && /^  [a-z]/ { on = 0 } on' "$1" | grep -c "$STEP"
}

# ============================================================================
# P1 the split moved bytes, it did not rewrite them
# ============================================================================
out=$("$RCW" --root "$DIR" --check 2>/dev/null); rc=$?
eq "P1 --check rc" "$rc" 0
eq "P1 --check stdout" "$out" ""
"$RCW" --root "$DIR" > "$T/p1.out" 2>/dev/null; rc=$?
eq "P1 print rc" "$rc" 0
cmp -s "$T/p1.out" "$DIR/$WFP" && ok || bad "P1: the render does not cmp equal to the committed $WFP"

# ============================================================================
# P2 one fragment per step, header holds no step
# ============================================================================
for pair in $JOBS; do
  d=${pair%%:*}; job=${pair#*:}; J="$DIR/$SRC/$d"
  nfiles=$(steps_in "$J" | wc -l | tr -d ' ')
  nrender=$(render_steps "$DIR/$WFP" "$job")
  eq "P2 $d step files == render steps of $job" "$nfiles" "$nrender"
  [ "$nfiles" -ge 1 ] && ok || bad "P2 $d: $nfiles step file(s), want at least 1"
  eq "P2 $d 000-job.yml step lines" "$(grep -c "$STEP" "$J/000-job.yml")" 0
  eq "P2 $d 000-job.yml first line" "$(head -1 "$J/000-job.yml")" "  $job:"
  eq "P2 $d 000-job.yml last line" "$(tail -1 "$J/000-job.yml")" "    steps:"
  while IFS= read -r f; do
    eq "P2 $d/$f step lines" "$(grep -c "$STEP" "$J/$f")" 1
  done < <(steps_in "$J")
done

# ============================================================================
# P3 a step slots in between two steps
# ============================================================================
for pair in $JOBS; do
  d=${pair%%:*}; job=${pair#*:}; R="$T/p3-$d"; seed "$R"
  f10=$(ls "$R/$SRC/$d"/010-*.yml 2>/dev/null | head -1)
  f20=$(ls "$R/$SRC/$d"/020-*.yml 2>/dev/null | head -1)
  if [ "$job" = main-ci ]; then next=$NEXT_JOB_AFTER_MAIN_CI; nextname="the next job header"
  else next=$(head -1 "$f20" 2>/dev/null); nextname="the first line of ${f20##*/}"; fi
  if [ -z "$f10" ] || { [ "$job" != main-ci ] && [ -z "$f20" ]; }; then
    bad "P3 $d: no 010 or 020 fragment"; continue
  fi
  printf '      - name: probe-%s\n        run: '"'"'true'"'"'\n' "$job" > "$R/$SRC/$d/015-probe.yml"
  "$RCW" --root "$R" > "$T/p3.out" 2>/dev/null; rc=$?
  eq "P3 $d print rc" "$rc" 0
  np=$(grep -nx "      - name: probe-$job" "$T/p3.out" | cut -d: -f1)
  nj=$(grep -nx "  $job:" "$T/p3.out" | cut -d: -f1)
  h=$(wc -l < "$R/$SRC/$d/000-job.yml"); a=$(wc -l < "$f10")
  want=$(( ${nj:-0} + h + a ))
  [ -n "$np" ] && [ -n "$nj" ] && [ "$np" -eq "$want" ] && ok \
    || bad "P3 $d: probe at line ${np:-none}, want $want (right after ${f10##*/})"
  eq "P3 $d $nextname follows the probe" \
    "$(sed -n "$(( ${np:-0} + 2 ))p" "$T/p3.out")" "$next"
  "$RCW" --root "$R" --check >/dev/null 2>&1; rc=$?
  eq "P3 $d --check with the probe" "$rc" 1
done

# ============================================================================
# N1 the slot rule is the renderer's: a capital slug is refused
# ============================================================================
R="$T/n1"; seed "$R"
printf '      - name: probe\n        run: '"'"'true'"'"'\n' > "$R/$SRC/210-prompt-evals/016-Probe.yml"
"$RCW" --root "$R" >/dev/null 2>&1; rc=$?
eq "N1 016-Probe.yml refused" "$rc" 3

echo "harness-ci-split-4.bh-7452: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
