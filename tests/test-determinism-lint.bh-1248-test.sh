#!/bin/bash
# tests/test-determinism-lint.bh-1248-test.sh — BH-1248: the race-sigpipe rule
# reaches bin/, reads a pipe that was continued onto the next line, and knows
# grep's long spellings of -q/-m.
#
#   THE PROPERTY UNDER TEST: a `git … | grep -q` in a bin/ script is a finding
#   (the shape BH-1232 measured at 75 reds in 400 runs), the OTHER seven rules
#   do not follow race-sigpipe into bin/, a pipe split over two physical lines
#   is judged as one pipeline, and `--max-count`/`--quiet`/`--silent` count as
#   short-circuiting consumers while `--count` does not.
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf (no DETERMINISM_LINT_CONF override): the claim
# is about the conf this repo ships, so a copy would prove nothing.
#
# determinism: ok-file the fixtures below are deliberate git-pipe leaks as DATA;
# this suite itself reads no clock, rolls no dice, and puts no short-circuiting
# consumer on a pipe.
# Run from anywhere: tests/test-determinism-lint.bh-1248-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run <dir-or-file> [flags...] -> stdout+stderr in $OUT, rc in $RC. HARNESS
# points at a scratch tree so a box-local flags/determinism-lint.conf cannot
# leak in and change the answer.
run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }
# count <re> -> the findings that match; the "first finding:" last line a failing
# run prints (BH-6880) repeats one finding's rule and is not counted again.
count() { grep -v '^test-determinism-lint: first finding: ' <<<"$OUT" | grep -c "$1"; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/tests" "$T/c/bin"; }

# ── A. the bin/ shape is caught ──────────────────────────────────────────────
# The whole point of the ticket: bin/ carries the same racy pipeline as tests/
# did, and today the lint never opens the file.
case_dir
cat > "$T/c/bin/lane.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git -C "$R" log --oneline ticket/x | grep -q 'the commit' && ok || bad "gone"
R=$(git -C "$R" show --name-only --format= x | head -1)
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'bin/lane\.sh:3: race-sigpipe' && has 'bin/lane\.sh:4: race-sigpipe'; } && ok \
  || bad "A: a git pipe in a bin/ script was not caught (rc=$RC): $OUT"

# ── A'. ONLY that rule follows into bin/ ─────────────────────────────────────
# Widening the whole `file` selector to bin/ fires 24 race-sleep, 3 rand-bash
# and 5 clock-rolling-window errors on today's tree, none of which this ticket
# asks anyone to fix. The scope directive is per rule, and this pins it.
cat >> "$T/c/bin/lane.sh" <<'EOF'
sleep 5
KEY="build-$RANDOM"
EOF
run "$T/c"
[ "$(count 'race-sleep\|rand-bash')" = 0 ] && ok \
  || bad "A': a rule with no scope line followed race-sigpipe into bin/: $OUT"
[ "$(count 'race-sigpipe')" = 2 ] && ok || bad "A': expected exactly 2 race-sigpipe findings: $OUT"

# ── B. a pipe continued onto the next line ───────────────────────────────────
# The rule reads one physical line, so every one of these three spellings is a
# race the lint waves through today (review N2 on PR #1235).
case_dir
cat > "$T/c/tests/cont-test.sh" <<'EOF'
git log --oneline ticket/x |
  grep -q 'the commit' && ok || bad "gone"
git log --oneline ticket/y \
  | grep -q 'other' && ok || bad "gone"
git log --oneline ticket/z | \
  grep -q 'third' && ok || bad "gone"
git log --oneline ticket/w |
  grep -c 'fourth'
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'cont-test\.sh:1: race-sigpipe' && has 'cont-test\.sh:3: race-sigpipe' \
    && has 'cont-test\.sh:5: race-sigpipe'; } && ok \
  || bad "B: a continued pipe was not judged as one pipeline (rc=$RC): $OUT"
[ "$(count 'race-sigpipe')" = 3 ] && ok \
  || bad "B: the finding must be reported once, at the git line, and the grep -c continuation not at all: $OUT"

# ── C. grep's long spellings of -q and -m ────────────────────────────────────
case_dir
cat > "$T/c/tests/long-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git log x | grep --max-count=1 foo && ok || bad "gone"
git log x | grep --max-count 1 foo && ok || bad "gone"
git log x | grep --quiet foo && ok || bad "gone"
git log x | grep --count foo
git log x | grep -e --max-countish foo
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'long-test\.sh:3: race-sigpipe' && has 'long-test\.sh:4: race-sigpipe' \
    && has 'long-test\.sh:5: race-sigpipe'; } && ok \
  || bad "C: --max-count / --quiet were not read as short-circuiting consumers (rc=$RC): $OUT"
[ "$(count 'race-sigpipe')" = 3 ] && ok \
  || bad "C: --count and a -e pattern that merely looks like a long flag must stay quiet: $OUT"

# ── D. the negatives stay quiet in bin/ too ──────────────────────────────────
# The lint gates CI red, so what it must NOT match is as load-bearing as what
# it must. These are the answers the rule's own comment recommends.
case_dir
cat > "$T/c/bin/quiet.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git log --oneline ticket/x | grep -c 'the commit'
git log --oneline ticket/x | wc -l
grep -q 'the commit' <<<"$(git log --oneline ticket/x)" && ok || bad "gone"
git merge-base --is-ancestor "$SHA" ticket/x && ok || bad "gone"
cat "$F" | grep -q 'the commit' && ok || bad "gone"
echo git-ish | grep -q 'the commit' && ok || bad "gone"   # determinism: ok race-sigpipe-echo seven bytes, written before grep reads
# git log --oneline ticket/x | grep -q 'the commit'   is a comment, not a race
git log --oneline ticket/x |
  grep -c 'the commit'
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe'; } && ok \
  || bad "D: a shape that is not a race was reported in bin/ (rc=$RC): $OUT"

# ── E. the existing waiver mechanism still works, on a bin/ file ─────────────
case_dir
cat > "$T/c/bin/waived.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git log --oneline ticket/x | grep -q 'the commit' && ok || bad "gone"   # determinism: ok the fixture branch is a single commit, git is done writing before grep matches
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe'; } && ok \
  || bad "E: a line waiver with a reason did not silence a bin/ finding (rc=$RC): $OUT"
cat > "$T/c/bin/waived.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git log --oneline ticket/x | grep -q 'the commit' && ok || bad "gone"   # determinism: ok
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'waiver-no-reason'; } && ok \
  || bad "E: a reasonless waiver in a bin/ file was accepted (rc=$RC): $OUT"

# ── F. --list shows the scoped files, --rules shows the directive ────────────
case_dir
: > "$T/c/bin/lane.sh"; : > "$T/c/tests/cont-test.sh"; : > "$T/c/README.md"
run "$T/c" --list
{ has 'bin/lane\.sh$' && has 'tests/cont-test\.sh$' && ! has 'README'; } && ok \
  || bad "F: --list did not print the scoped bin/ file: $OUT"
run --rules
{ [ "$RC" = 0 ] && has '^scope race-sigpipe'; } && ok || bad "F: --rules must print the scope lines: $OUT"

echo "test-determinism-lint.bh-1248: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
