#!/bin/bash
# tests/patch-same-callers.bh-9066-test.sh — which callers may accept a schema
# restamp as "the same patch" (BH-9066, slice C0).
#
# A restamp keeps the REVIEWED work the same, but it moves the fragment in the
# composed schema order, so a CI or test result must never cross to it.
#   P1  review callers ask the restamp-aware rung: the conductor rebind
#       (mc_patch_id_rebind passes `review` to mc_patch_same), lead_carry and
#       ld_classify (patch_same_restamp), gate 50, review-prs and
#       review-autopilot (patch_same_review).
#   P2  byte callers (CI and test reuse) never name patch_same_review or
#       patch_same_restamp, and the failed-batch module calls mc_patch_same
#       with 4 arguments only.
#   P3  bin/lead-review.sh keeps its 3 attempts per head (Fix 3 is not in C0).
# The behavior of each review caller is driven in tests/mc-rebind-restamp,
# tests/lead-carry-restamp-rebase and tests/review-replay-restamp (bh-9066);
# this suite pins the split so a later edit cannot move a byte caller across.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# has <file> <fixed-string> <label> — the file exists and holds the string on a non-comment line
has() {
  local f="$DIR/$1"
  [ -f "$f" ] || { bad "$3: $1 does not exist"; return; }
  grep -qF -- "$2" <<<"$(grep -vE '^[[:space:]]*#' "$f")" && ok || bad "$3: $1 has no '$2'"
}
# hasnt <file> <ERE> <label> — the file exists and no line matches
hasnt() {
  local f="$DIR/$1" hits
  [ -f "$f" ] || { bad "$3: $1 does not exist"; return; }
  hits=$(grep -nE -- "$2" "$f")
  [ -z "$hits" ] && ok || bad "$3: $1 must not match /$2/: $hits"
}

# ---- P1: review callers
has bin/lib/mc/settle.sh 'mc_patch_same "$slug" "$project" "$rev" "$head" review' "P1 conductor rebind"
has bin/lib/mc/settle.sh 'fn=patch_same_review' "P1 mc_patch_same review mode"
has bin/lib/lead-carry.sh 'how=$(patch_same_restamp "$repo" origin/main "$ph" "$head")' "P1 lead_carry"
has bin/lib/lead-delta.sh 'how=$(patch_same_restamp "$g" "$main" "$gs" "$hs")' "P1 ld_classify"
has bin/lib/lead-gates.d/50-replay-delta.sh 'patch_same_review "$repo" origin/main "$ph" "$head"' "P1 gate 50"
has bin/review-prs.sh 'patch_same_review "$REPO_DIR" origin/main "$DONE" "$SHA"' "P1 review-prs"
has bin/review-autopilot.sh 'patch_same_review "$AP_REPO" origin/main' "P1 review-autopilot"

# ---- P2: byte callers stay byte
for f in bin/lib/merge-push.sh bin/lib/builder-carry.sh bin/lib/lead-review/gate-record.sh bin/ci-merge-reuse.sh \
         bin/lib/rb/pr.sh bin/lib/lead-gates.d/10-builder.sh bin/merge-conductor.d/bh-8186-failed-batch.sh \
         bin/lib/lead-gates.d/07-merge-carry.sh; do
  hasnt "$f" 'patch_same_review|patch_same_restamp' "P2 byte caller"
done
fb=bin/merge-conductor.d/bh-8186-failed-batch.sh
n=$(grep -cE 'mc_patch_same "\$SLUG" "\$P" "\$rh" "\$HEAD" >' "$DIR/$fb")
[ "$n" -ge 1 ] && ok || bad "P2 $fb: the 4-argument mc_patch_same call is gone (found $n), so this pin no longer proves anything"
hasnt "$fb" 'mc_patch_same [^>]* review' "P2 failed-batch keeps 4 arguments"
# The merge-only lead carry (gate 07, BH-8705) keeps its main-merge-only rule.
has bin/lib/lead-carry.sh 'if [ "$how" != main-merge ]; then' "P2 lead_carry merge-only mode"

# ---- P3: the per-head attempt rule is unchanged
grep -qF '# (3 = no claim; unreadable = no claim this tick), and the per-PR' "$DIR/bin/lead-review.sh" && ok \
  || bad "P3 bin/lead-review.sh: the 3-attempts-per-head rule text changed"

echo "patch-same-callers.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
