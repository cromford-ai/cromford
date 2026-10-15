#!/bin/bash
# tests/test-determinism-lint.bh-6880-test.sh — BH-6880: when the lint fails,
# its LAST line names its first finding:
#   test-determinism-lint: first finding: <file>:<line>: <rule>
#
#   WHY: bin/main-red-pr-pair.sh groups failing PRs on (job, first error), and
#   the first error of a job is the line before the runner's generic
#   "Process completed with exit code 1." That line used to be the lint's fixed
#   footer, so any two PRs that failed this lint paired and paged a false
#   main-red (#6867 + #6875, 2026-10-15). The footer stays, one line above.
#
# The line names file, line and rule only: no count and no message, so two PRs
# that share one inherited finding still read the same line. It appears only on
# rc 1: a clean run, a warnings-only run and --warn-only print no such line.
# bin/lib/prepr-gate.sh parses the lint's findings section; case F runs its awk
# on the output and checks the new line is not read as a finding.
#
# determinism: ok-file the fixtures below are deliberate sleeps, pipes and date
# stamps as DATA for the lint; this suite reads no clock and never sleeps.
# Run from anywhere: tests/test-determinism-lint.bh-6880-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
last()   { tail -n 1 <<<"$OUT"; }
second() { tail -n 2 <<<"$OUT" | head -n 1; }
nofirst() { ! grep -q 'first finding:' <<<"$OUT"; }

# Tree A: two error findings in two files. tests/a1.sh sorts before tests/b2.sh.
mkdir -p "$T/A/tests"
printf '#!/bin/bash\necho one\nsleep 5\n' > "$T/A/tests/a1.sh"
printf '#!/bin/bash\nX=abc\nprintf %%s "$X" | grep -q b && echo hit\n' > "$T/A/tests/b2.sh"
# Tree C: clean. Tree D: one warning only (clock-date-cmd is warn).
mkdir -p "$T/C/tests" "$T/D/tests"
printf '#!/bin/bash\necho clean\n' > "$T/C/tests/c.sh"
printf '#!/bin/bash\nd=$(date -u +%%Y)\necho "$d"\n' > "$T/D/tests/d.sh"

# ── A. rc 1, the last line names the FIRST finding ──────────────────────────
run "$T/A"
[ "$RC" = 1 ] && ok || bad "A: two findings must exit 1, got $RC: $OUT"
first_sec=$(awk '/^── determinism findings \(fail\)/{f=1;next} f && /^[^[:space:]]/{print; exit}' <<<"$OUT")
case "$first_sec" in *tests/a1.sh:3:\ race-sleep:*) ok ;; *) bad "A: fixture: findings section does not open with a1.sh: '$first_sec'" ;; esac
want="test-determinism-lint: first finding: ${first_sec%%: race-sleep:*}: race-sleep"
[ "$(last)" = "$want" ] && ok || bad "A: last line '$(last)', want '$want'"
case "$(last)" in *b2.sh*) bad "A: the last line names the second finding: '$(last)'" ;; *) ok ;; esac
grep -q 'tests/b2.sh:3: race-sigpipe-echo' <<<"$OUT" && ok || bad "A: fixture: b2.sh must be a finding too: $OUT"

# ── B. the footer is unchanged and second to last ───────────────────────────
[ "$(second)" = "Fix the line, pin the file's clock, or waive it with a reason:  # determinism: ok <why this is deterministic>" ] \
  && ok || bad "B: second-to-last line is not the footer: '$(second)'"

# ── C. clean tree: rc 0, no first-finding line ──────────────────────────────
run "$T/C"
[ "$RC" = 0 ] && nofirst && ok || bad "C: clean tree rc=$RC or printed a first finding: $OUT"

# ── D. warnings only: rc 0, no first-finding line ───────────────────────────
run "$T/D"
{ [ "$RC" = 0 ] && grep -q 'd.sh:2: clock-date-cmd' <<<"$OUT" && nofirst; } && ok \
  || bad "D: warnings-only rc=$RC, must warn and print no first finding: $OUT"

# ── E. --warn-only on tree A: rc 0, no first-finding line ───────────────────
run --warn-only "$T/A"
{ [ "$RC" = 0 ] && grep -q 'tests/a1.sh:3: race-sleep' <<<"$OUT" && nofirst; } && ok \
  || bad "E: --warn-only rc=$RC, must report and print no first finding: $OUT"

# ── F. prepr-gate's findings awk still reads exactly 2 findings ─────────────
run "$T/A"
awkp=$(grep -F "/^── determinism findings" "$DIR/bin/lib/prepr-gate.sh" | sed -E "s/^[[:space:]]*awk '([^']*)'.*/\1/")
[ -n "$awkp" ] && ok || bad "F: cannot find the findings awk in bin/lib/prepr-gate.sh"
n=$(awk "$awkp" <<<"$OUT" | awk 'END{print NR+0}')
[ "$n" = 2 ] && ok || bad "F: prepr-gate's awk read $n findings, want 2: $(awk "$awkp" <<<"$OUT")"

echo "test-determinism-lint.bh-6880: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
