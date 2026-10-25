#!/bin/bash
# tests/lead-gates-selfcheck-zero.bh-7236-test.sh — the pre-review self-check
# gate (bin/lib/lead-gates.d/75-self-check.sh, bin/lib/lead-gates-selfcheck.sh)
# with PR_SELF_CHECK_MAX_WAIT_MIN=0: the refused body is commented on and the
# lead review is requested on the same tick. Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh) on a real head in the clone.
#   Z1  wait 0, a refused body: ONE PR comment; it names closes-not-met and
#       says "The lead review is requested now"; it does not say "no lead
#       review is requested yet" or "After 0 minutes".
#   Z2  the same tick opens one lead_review job, and its self_check_notes
#       (the scope-note field, lg_scope_notes) carries `self-check: closes-not-met`.
#   Z3  the wait unset (default 30): the comment says "After 30 minutes"; no job.
#   M1  the selfcheck lib without its wait-0 branch: Z1 goes red (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-selfcheck-zero.bh-7236-test.sh
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
unset PR_SELF_CHECK PR_SELF_CHECK_MAX_WAIT_MIN
lwf_setup
lgf_setup
lg6_setup
LIB="$H/bin/lib/lead-gates-selfcheck.sh"
for f in bin/lib/lead-gates.d/75-self-check.sh bin/lib/lead-gates-selfcheck.sh bin/lib/pr-self-check.sh; do
  [ -r "$LWF_SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
HS=$(lg6_head 104 s/new.txt "a new file") || bad "setup: the head"
S12=${HS:0:12}
BAD="Closes #7

$LG6_BODY- [ ] gate 7 runs on the worklist
"
CM="$T/log/comments.104"
# one — PR 104 on the real head with the refused body, the catalog in
one() { lg6_reset none; lgf_needs "104:$HS"; printf '%s' "$BAD" > "$FX/body.104"; lg6_catalog; }
# z1 — the Z1 comment holds: one comment, the rule, "requested now", no hold text
z1() {
  [ "$(lg6_comments 104)" = 1 ] && grep -q '^- closes-not-met: ' "$CM" \
    && grep -qF "refused this PR body on head \`$S12\`:" "$CM" \
    && grep -qF 'The lead review is requested now' "$CM" \
    && ! grep -qF 'no lead review is requested yet' "$CM" && ! grep -qF 'After 0 minutes' "$CM"
}

# ── Z1 + Z2: wait 0: one comment, and a job on the same tick ──
one
PR_SELF_CHECK_MAX_WAIT_MIN=0 lwf_tick
z1 && ok || bad "Z1 comments=$(lg6_comments 104): $(cat "$CM" 2>/dev/null)"
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "Z2 jobs=$(lgf_jobs 104) with wait 0: $(cat "$L")"
[[ "$(lg6_meta 104 self_check_notes)" == "self-check: closes-not-met: "* ]] && ok \
  || bad "Z2 self_check_notes='$(lg6_meta 104 self_check_notes)'"

# ── Z3: the default wait: the hold text names 30 minutes, no job yet ──
one
lwf_tick
[ "$(lg6_comments 104)" = 1 ] && grep -qF 'After 30 minutes the lead review is requested anyway' "$CM" && ok \
  || bad "Z3 comment: $(cat "$CM" 2>/dev/null)"
grep -qF 'The lead review is requested now' "$CM" && bad "Z3 the default wait said 'requested now'" || ok
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "Z3 a job on the first tick with the default wait"

# ── M1: no wait-0 branch in the lib: Z1 goes red ──
cp "$LIB" "$T/selfcheck.orig"
sed -i 's/if \[ "\$LGK_PSCMAX" -eq 0 \]; then/if false; then/' "$LIB"
if cmp -s "$LIB" "$T/selfcheck.orig"; then
  bad "M1 the mutation did not change the lib"
else
  one
  PR_SELF_CHECK_MAX_WAIT_MIN=0 lwf_tick
  z1 && bad "M1 Z1 stayed green without the wait-0 branch" || ok
fi
cp "$T/selfcheck.orig" "$LIB"

echo "lead-gates-selfcheck-zero.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
