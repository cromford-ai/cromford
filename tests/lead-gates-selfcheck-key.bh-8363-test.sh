#!/bin/bash
# tests/lead-gates-selfcheck-key.bh-8363-test.sh — the pre-review self-check
# gate (bin/lib/lead-gates.d/75-self-check.sh, lgsc_run in
# bin/lib/lead-gates-selfcheck.sh) passes the PR title key to psc_check as
# PSC_PR_KEY and narrows no rule. These cases moved here from the enqueue text
# reads of BH-6392 E1 and BH-6393 S2 (BH-8363). Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh) on a real head in the clone that edits
# tests/x.bh-100-test.sh, a test of another key.
#   K1  title `BH-200: t`, no TEST-CHANGE line: no job, ONE PR comment, and it
#       has a `- test-ownership: ` line.
#   K2  title `BH-100: t` (the test's own key): one comment (closes-not-met, so
#       the check visibly ran) and no `test-ownership` line in it.
#   K3  a title with no key: one comment (closes-not-met) and no
#       `test-ownership` refusal line (no key is a NOTE, BH-6392 K3).
#   K4  title `BH-200: t` and a closes-not-met body: ONE comment with both
#       `- closes-not-met: ` and `- test-ownership: `. A body rule and a diff
#       rule ran in one check: the worklist call narrows no rule
#       (PR_SELF_CHECK_ONLY is unset in this suite).
#   M1  the lib with PSC_PR_KEY="" in place of the title key: K1 goes red (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-selfcheck-key.bh-8363-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset PR_SELF_CHECK PR_SELF_CHECK_MAX_WAIT_MIN PR_SELF_CHECK_ONLY PSC_PR_KEY
lwf_setup
lgf_setup
lg6_setup
LIB="$H/bin/lib/lead-gates-selfcheck.sh"
[ -r "$LIB" ] && ok || bad "setup: $LIB not installed"
M=$(lg6_main tests/x.bh-100-test.sh "echo v1") || bad "setup: main"
HS=$(lg6_head 108 tests/x.bh-100-test.sh "echo v2" "$M") || bad "setup: the head"
CLOSES="Closes #7

$LG6_BODY- [ ] gate 7 runs on the worklist
"
CM="$T/log/comments.108"
# one <title> <body> — PR 108 on the real head, the catalog in
one() { lg6_reset none; lgf_needs "108:$HS"; printf '%s' "$1" > "$FX/title.108"; printf '%s' "$2" > "$FX/body.108"; lg6_catalog; }
# k1 — the K1 outcome: no job, one comment, a test-ownership line in it
k1() { [ "$(lgf_jobs 108)" = 0 ] && [ "$(lg6_comments 108)" = 1 ] && grep -q '^- test-ownership: ' "$CM"; }

# ── K1: another key's title: the title key reaches psc_check ──
one 'BH-200: t' "$LG6_BODY"
lwf_tick
k1 && ok || bad "K1 jobs=$(lgf_jobs 108) comments=$(lg6_comments 108): $(cat "$CM" 2>/dev/null)"

# ── K2: the test's own key: no test-ownership refusal ──
one 'BH-100: t' "$CLOSES"
lwf_tick
[ "$(lg6_comments 108)" = 1 ] && grep -q '^- closes-not-met: ' "$CM" && ok \
  || bad "K2 the check did not run: comments=$(lg6_comments 108): $(cat "$CM" 2>/dev/null)"
grep -q 'test-ownership' "$CM" 2>/dev/null && bad "K2 the own key was refused: $(cat "$CM")" || ok

# ── K3: no key in the title: no test-ownership refusal ──
one 'fix: a lead fix' "$CLOSES"
lwf_tick
[ "$(lg6_comments 108)" = 1 ] && grep -q '^- closes-not-met: ' "$CM" && ok \
  || bad "K3 the check did not run: comments=$(lg6_comments 108): $(cat "$CM" 2>/dev/null)"
grep -q '^- test-ownership: ' "$CM" 2>/dev/null && bad "K3 no key was refused: $(cat "$CM")" || ok

# ── K4: a body rule and a diff rule in one check ──
one 'BH-200: t' "$CLOSES"
lwf_tick
{ [ "$(lgf_jobs 108)" = 0 ] && [ "$(lg6_comments 108)" = 1 ] && grep -q '^- closes-not-met: ' "$CM" \
  && grep -q '^- test-ownership: ' "$CM"; } && ok \
  || bad "K4 jobs=$(lgf_jobs 108) comments=$(lg6_comments 108): $(cat "$CM" 2>/dev/null)"

# ── M1: the lib drops the title key: K1 goes red ──
cp "$LIB" "$T/selfcheck.orig"
sed -i 's/PSC_PR_KEY="\$tk"/PSC_PR_KEY=""/' "$LIB"
if cmp -s "$LIB" "$T/selfcheck.orig"; then
  bad "M1 the mutation did not change the lib"
else
  one 'BH-200: t' "$LG6_BODY"
  lwf_tick
  k1 && bad "M1 K1 stayed green without the title key" || ok
fi
cp "$T/selfcheck.orig" "$LIB"

echo "lead-gates-selfcheck-key.bh-8363: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
