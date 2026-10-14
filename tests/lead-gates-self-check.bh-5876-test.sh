#!/bin/bash
# tests/lead-gates-self-check.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 7 of
# the enqueue, the pre-review self-check (BH-5798), as the worklist gate
# bin/lib/lead-gates.d/75-self-check.sh (bin/lib/lead-gates-selfcheck.sh, the
# real bin/lib/pr-self-check.sh and catalog/pr-self-check.tsv). Every case
# drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh) on a real head in the clone.
#   S1  the body says Closes #7 and an acceptance item is open (closes-not-met):
#       held, ONE PR comment naming the rule, no job, one `[skip selfcheck]`.
#   S2  a clean body: a job.
#   S3  PR_SELF_CHECK=0: S1's body gets a job.
#   S4  a hold marker older than the bound: a job, and its meta
#       self_check_notes starts with `self-check: closes-not-met`.
#   S5  a second tick on the same head and body: no second comment and no
#       second skip line. A changed body: one new comment.
#   S6  no catalog: S1's body gets a job.
#   S7  the order: a low-tier head under enforce with S1's body is signed off
#       by the risk tier (60-risk.sh) and never held here.
#   M1  75-self-check.sh removed: S1 gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-self-check.bh-5876-test.sh
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
lwf_setup
lgf_setup
lg6_setup
GD="$H/bin/lib/lead-gates.d"
SRC="$LWF_SRC"
for f in bin/lib/lead-gates.d/75-self-check.sh bin/lib/lead-gates-selfcheck.sh bin/lib/pr-self-check.sh; do
  [ -r "$SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
HS=$(lg6_head 104 s/new.txt "a new file") || bad "setup: the head"
S12=${HS:0:12}
MK="$H/state/lead-review-enqueue/selfcheck-example-org_cromford-104-$S12"
NF="$H/state/lead-review-enqueue/selfcheck-notes-example-org_cromford-104-$S12"
BAD="Closes #7

$LG6_BODY- [ ] gate 7 runs on the worklist
"
summ() { lwf_summary; }
# one <body> [risk mode] — PR 104 on the real head with <body>, the catalog in
one() { lg6_reset "${2:-none}"; lgf_needs "104:$HS"; printf '%s' "$1" > "$FX/body.104"; lg6_catalog; }

# ── S1: a refused body: held, one comment, no job ──
one "$BAD"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "S1 a job on a refused body: $(cat "$L")"
[ "$(lg6_comments 104)" = 1 ] && ok || bad "S1 comments=$(lg6_comments 104)"
grep -q '^- closes-not-met: ' "$T/log/comments.104" && ok || bad "S1 the comment: $(cat "$T/log/comments.104" 2>/dev/null)"
grep -qF "refused this PR body on head \`$S12\`, so no lead review is requested yet" "$T/log/comments.104" && ok || bad "S1 comment text"
[ "$(lg6_skips selfcheck)" = 1 ] && ok || bad "S1 selfcheck lines=$(lg6_skips selfcheck): $(cat "$L")"
grep -q "^commented [0-9]*$" "$MK" && ok || bad "S1 marker: $(cat "$MK" 2>/dev/null)"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "S1 summary: $(summ)"

# ── S5: the same head and body again: nothing new; a new body: one comment ──
lwf_tick
[ "$(lg6_comments 104)" = 1 ] && ok || bad "S5 a second comment on the same body"
[ "$(lg6_skips selfcheck)" = 1 ] && ok || bad "S5 a second skip line"
printf '%s' "$BAD
- [ ] and one more item" > "$FX/body.104"
lwf_tick
[ "$(lg6_comments 104)" = 2 ] && ok || bad "S5 comments=$(lg6_comments 104) after a body change"
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "S5 a job"

# ── S2: a clean body: a job ──
one "$LG6_BODY"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "S2 no job on a clean body: $(cat "$L")"
[ "$(lg6_comments 104)" = 0 ] && ok || bad "S2 a comment on a clean body: $(cat "$T/log/comments.104")"

# ── S3: the check off ──
one "$BAD"
PR_SELF_CHECK=0 lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "S3 no job with PR_SELF_CHECK=0"
[ "$(lg6_comments 104)" = 0 ] && ok || bad "S3 a comment with the check off"

# ── S4: the bound reached: a job with the findings in its notes ──
one "$BAD"
mkdir -p "${MK%/*}"; echo "$(( $(date +%s) - 3600 ))" > "$MK"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "S4 no job past the bound: $(cat "$L")"
[[ "$(lg6_meta 104 self_check_notes)" == "self-check: closes-not-met: "* ]] && ok || bad "S4 self_check_notes='$(lg6_meta 104 self_check_notes)'"
[ "$(cat "$NF" 2>/dev/null)" = "$(lg6_meta 104 self_check_notes)" ] && ok || bad "S4 the notes file and the meta differ"
grep -qF "example-org/cromford#104 @$S12: self-check still refused after 30m; starting anyway" "$L" && ok || bad "S4 line: $(cat "$L")"

# ── S6: no catalog ──
one "$BAD"; rm -f "$H/catalog/pr-self-check.tsv"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "S6 no job with no catalog"

# ── S7: a low-tier head is signed off before the self-check ──
one "$BAD" enforce
lgf_cmp "$HS" '[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
lwf_tick
[ "$(lgf_signed 104)" = 1 ] && ok || bad "S7 sign-offs=$(lgf_signed 104): $(cat "$L")"
[ "$(lg6_comments 104)" = 0 ] && ok || bad "S7 a self-check comment on a signed-off head"
[ "$(lg6_skips selfcheck)" = 0 ] && ok || bad "S7 a selfcheck line on a signed-off head"

# ── M1: no self-check gate: S1 gets a job ──
mv "$GD/75-self-check.sh" "$T/75.off"
one "$BAD"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M1 no job with 75-self-check.sh gone: $(cat "$L")"
mv "$T/75.off" "$GD/75-self-check.sh"

echo "lead-gates-self-check.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
