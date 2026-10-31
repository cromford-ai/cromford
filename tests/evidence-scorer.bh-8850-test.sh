#!/bin/bash
# tests/evidence-scorer.bh-8850-test.sh — a harness-suite file whose run never
# ran (`HARNESS_EXIT: could-not-run`, `no-test-script`) must not refute or
# confirm a claim (bin/lib/evidence.sh, BH-8850). Live case: project-6#3443 at
# 2f8537c3 was BLOCKED on two REFUTED rows read from a could-not-run file.
#
#   §1 the real `evidence_score` (the entry point bin/lib/rb/review.sh and
#      bin/lib/rb/result.sh use) on a one-claim plan: cases A, B, C, K, L.
#   §2 `evidence_locate` decision table: cases D-J.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/evidence-scorer.bh-8850-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

# shellcheck source=../bin/lib/evidence.sh
. "$DIR/bin/lib/evidence.sh" || { echo "bh-8850: cannot source bin/lib/evidence.sh"; exit 1; }

TST=tests/unit/builder-save-trigger.TK-2761.test.ts
G="-c user.name=t -c user.email=t@example.com"
# A scratch repo where the named test is untouched, so the staging check says
# nothing and only the located evidence decides.
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main >/dev/null 2>&1
printf 'x\n' > "$R/README"
git -C "$R" add -A >/dev/null 2>&1
# shellcheck disable=SC2086
git -C "$R" $G commit -q -m base >/dev/null 2>&1
git -C "$R" checkout -q -b feature >/dev/null 2>&1

plan1() { # plan1 <build> — a one-claim plan naming $TST
  mkdir -p "$1"
  printf '## Acceptance tests\n- the save trigger fires, proven by `%s`\n' "$TST" > "$1/plan.md"
}
score() { SOUT=$(evidence_score "$1" "$1/plan.md" main "$R" 2>&1); SRC=$?; }
j() { jq -r "$2" "$1/evidence.json" 2>/dev/null; }
claim1() { printf '%s\n' "$SOUT" | grep '^CLAIM 1:'; }
loc() { evidence_locate "$1" "$TST" | cut -f"$2"; }

# ── §1 evidence_score end to end ─────────────────────────────────────────────
# A: FAIL + could-not-run, no other source → INCONCLUSIVE with the note.
B="$T/a"; plan1 "$B"
printf 'FAIL %s\nHARNESS_EXIT: could-not-run\n' "$TST" > "$B/harness-suite.txt"
score "$B"
eq "A the scorer returns 0" "$SRC" "0"
eq "A could-not-run FAIL is not REFUTED" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
eq "A the note names the file" "$(j "$B" '.claims[0].note')" "harness suite could not run (harness-suite.txt)"
has "A the CLAIM line says INCONCLUSIVE" "$(claim1)" "CLAIM 1: INCONCLUSIVE"
has "A the CLAIM line carries the note" "$(claim1)" "harness suite could not run (harness-suite.txt)"
eq "A refuted count is 0" "$(j "$B" '.refuted')" "0"

# B: the same FAIL in a real run (HARNESS_EXIT: 1) still refutes.
B="$T/b"; plan1 "$B"
printf 'FAIL %s\nHARNESS_EXIT: 1\n' "$TST" > "$B/harness-suite.txt"
score "$B"
eq "B a real-run FAIL is REFUTED" "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "B the artifact is that line" "$(j "$B" '.claims[0].artifact')" "harness-suite.txt:1"

# C: could-not-run head file FAIL, real harness-suite.txt PASS → CONFIRMED.
B="$T/c"; plan1 "$B"
printf 'FAIL %s\nHARNESS_EXIT: could-not-run\n' "$TST" > "$B/harness-suite-head.txt"
printf 'run start\nPASS %s\nHARNESS_EXIT: 0\n' "$TST" > "$B/harness-suite.txt"
score "$B"
eq "C the real file confirms" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"
eq "C the artifact is the real file's line" "$(j "$B" '.claims[0].artifact')" "harness-suite.txt:2"

# K: could-not-run harness file + a validate.txt run line with EXIT: 0.
B="$T/k"; plan1 "$B"
printf 'FAIL %s\nHARNESS_EXIT: could-not-run\n' "$TST" > "$B/harness-suite.txt"
printf 'TASK T3\n$ npx vitest run %s\nEXIT: 0\n' "$TST" > "$B/validate.txt"
score "$B"
eq "K validate.txt decides next" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"
eq "K the artifact is agent-recorded" "$(j "$B" '.claims[0].artifact')" "validate.txt:2 (agent-recorded)"

# L: a could-not-run file that never names the test leaves the old note.
B="$T/l"; plan1 "$B"
printf 'FAIL tests/unit/other.test.ts\nHARNESS_EXIT: could-not-run\n' > "$B/harness-suite.txt"
score "$B"
eq "L still INCONCLUSIVE" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
has "L keeps the old note" "$(j "$B" '.claims[0].note')" "named test never appears in harness-suite*.txt or validate.txt ($TST)"

# ── §2 evidence_locate decision table ────────────────────────────────────────
mk() { mkdir -p "$1"; printf "$2" "$TST" > "$1/harness-suite.txt"; }

B="$T/d"; mk "$B" 'FAIL %s\nHARNESS_EXIT: no-test-script\n'
eq "D no-test-script decides nothing" "$(loc "$B" 1)" "none"
eq "D the note names the file" "$(loc "$B" 3)" "harness suite could not run (harness-suite.txt)"

B="$T/e"; mk "$B" 'FAIL %s\n'
eq "E no HARNESS_EXIT line keeps the old fail" "$(loc "$B" 1)" "fail"
eq "E artifact" "$(loc "$B" 2)" "harness-suite.txt:1"

B="$T/f"; mk "$B" 'FAIL %s\nHARNESS_EXIT: 124\n'
eq "F a timeout (124) is a real run" "$(loc "$B" 1)" "fail"

B="$T/g"; mk "$B" 'HARNESS_EXIT: could-not-run\nFAIL %s\nHARNESS_EXIT: 1\n'
eq "G the last HARNESS_EXIT (1) wins" "$(loc "$B" 1)" "fail"
eq "G artifact" "$(loc "$B" 2)" "harness-suite.txt:2"

B="$T/h"; mk "$B" 'PASS %s\nHARNESS_EXIT: 0\nHARNESS_EXIT: could-not-run\n'
eq "H the last HARNESS_EXIT (could-not-run) wins: a PASS never confirms" "$(loc "$B" 1)" "none"
eq "H note" "$(loc "$B" 3)" "harness suite could not run (harness-suite.txt)"

B="$T/i"; mk "$B" 'the gate wrote HARNESS_EXIT: could-not-run\nFAIL %s\nHARNESS_EXIT: 1\n'
eq "I a prose HARNESS_EXIT is not line-leading" "$(loc "$B" 1)" "fail"

B="$T/i2"; mk "$B" 'FAIL %s\nHARNESS_EXIT: 1\nthe gate wrote HARNESS_EXIT: could-not-run\n'
eq "I a later prose HARNESS_EXIT does not override the real one" "$(loc "$B" 1)" "fail"

B="$T/j"; mk "$B" 'FAIL %s\nHARNESS_EXIT:   could-not-run  \n'
eq "J extra spaces still skip the file" "$(loc "$B" 1)" "none"
eq "J note" "$(loc "$B" 3)" "harness suite could not run (harness-suite.txt)"

echo "evidence-scorer.bh-8850: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
