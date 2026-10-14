#!/bin/bash
# tests/br-ladder-test.sh — the blocked-resolver's CLASSIFIER, section 1 of the
# old tests/blocked-resolver-test.sh, moved here verbatim by BH-1196 and named
# for the module that owns it, bin/lib/br/ladder.sh.
#
# WHY IT IS THE FIRST SUITE. The resolver's whole value is that it makes a
# decision where the old code made a request, and the cheapest way that goes
# wrong is silently: a park classified into the wrong action means a real
# iron-law violation gets rebuilt into existence again. So the classifier is
# EXTRACTED from the running script and driven — a table in the test that agrees
# with a table in the test proves nothing.
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   1.  the classifier: every reason class maps to the action the ladder owes it
# Run from anywhere: tests/br-ladder-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# ============================================================================
# 1. The classifier: every reason class maps to the action the ladder owes it.
#    Driven through the script's own function, not re-derived here — a table in
#    the test that agrees with a table in the test proves nothing.
# ============================================================================
# The classifier is EXTRACTED and driven, the way tests/conductor-owns-merges-test.sh
# extracts the tier-1 gate: sourcing the whole script would run the drain.
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
: > "$T/cls.sh"
for fn in br_action br_reason_of br_ladder_class br_ladder_rung br_skips_mechanical; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/cls.sh"
done
[ -s "$T/cls.sh" ] && ok || bad "could not extract br_action/br_reason_of/br_ladder_class/br_ladder_rung"
cls() { bash -c '. "$0"; br_action "$(br_reason_of "$1")"' "$T/cls.sh" "$1"; }
raw() { bash -c '. "$0"; br_action "$1"' "$T/cls.sh" "$1"; }
klass() { bash -c '. "$0"; br_ladder_class "$1"' "$T/cls.sh" "$1"; }
rung()  { bash -c '. "$0"; br_ladder_rung "$1" "$2" "$3"' "$T/cls.sh" "$1" "$2" "$3"; }
# The 4th argument is the FIX CAP this ticket has bought (BH-579): a small
# conflict gets two rounds, and a contested winner gets a bonus one on top.
rung4() { bash -c '. "$0"; br_ladder_rung "$1" "$2" "$3" "$4"' "$T/cls.sh" "$1" "$2" "$3" "$4"; }
# THE THREE BRANCH CLASSES GO TO THE LADDER, not straight to the most expensive
# rung on the board. 24h of the live log before this: 121 rebuild-fresh, ZERO
# fix rounds — and a rebase conflict and a red CI run are the two cheapest
# things in this harness to actually fix.
for pair in "conflict-unresolvable:ladder" "rebase-gate-red:ladder" \
            "queue-ejected-twice:ladder" "merge-failed-twice:rebuild-fresh" \
            "red-ci-twice:ladder" "red-twice:ladder" \
            "head-not-reapproved:ladder" "orphaned-child:ladder" \
            "no-verdict:re-review" "iron-law:adjudicate"; do
  r="${pair%%:*}"; want="${pair##*:}"
  got=$(cls "$r: some detail the lane appended")
  [ "$got" = "$want" ] && ok || bad "reason '$r' must classify as $want, got '$got'"
done
for pair in "test-tamper:adjudicate" "rescue-real-deletion:adjudicate" \
            "reproduction-gate:rebuild-fresh" "intent-gate:rebuild-fresh" \
            "pool-died-twice:rebuild-fresh" "pool-deferred-max:rebuild-fresh" \
            "rescue-giving-up:rebuild-fresh" "plan-malformed:rebuild-fresh" \
            "plan-blocked:rebuild-fresh" "build-dead:rebuild-fresh" \
            "rebuild-build-dead:rebuild-fresh" "rebuild-decompose-failed:abandon-rebuild" \
            "rebuild-plan-blocked:abandon-rebuild" "rebuild-review-blocked:abandon-rebuild"; do
  r="${pair%%:*}"; want="${pair##*:}"
  got=$(raw "$r")
  [ "$got" = "$want" ] && ok || bad "reason '$r' must classify as $want, got '$got'"
done
# A REBUILD's OWN outcome is not the ORIGINAL park's: `build-dead` is a record
# this lane has never acted on, `rebuild-build-dead` is the rebuild this lane
# itself enqueued dying, and only the second one may spend the next counter
# without re-closing a PR that is already closed.
for pair in "rebuild-build-dead: the pool machine went away again:rebuild-build-dead" \
            "rebuild-decompose-failed: DECOMPOSE_FAILED see /x:rebuild-decompose-failed" \
            "rebuild-plan-blocked: PLAN_BLOCKED see /x:rebuild-plan-blocked" \
            "rebuild-review-blocked: REVIEW_BLOCKED see /x:rebuild-review-blocked"; do
  r="${pair%:*}"; want="${pair##*:}"
  got=$(bash -c '. "$0"; br_reason_of "$1"' "$T/cls.sh" "$r")
  [ "$got" = "$want" ] && ok || bad "reason '$r' must normalise to $want, got '$got'"
done
# BUILD_DEAD IS THE ONE THAT MUST NOT CLIMB. The machine went away with the
# work: there is no branch to merge main into, no findings to fix, nothing an
# agent could be briefed with. A ladder entry for it would buy two empty rungs
# before doing the only thing that can work.
[ -z "$(klass build-dead)" ] && ok || bad "build-dead must have NO ladder class (got '$(klass build-dead)')"
[ "$(raw build-dead)" = rebuild-fresh ] && ok || bad "build-dead must go straight to rebuild-fresh"
# The class map itself.
for pair in "conflict-unresolvable:rebase-conflict" "rebase-gate-red:rebase-conflict" \
            "red-ci-twice:ci-red" "red-twice:ci-red" "queue-ejected-twice:ci-red" \
            "head-not-reapproved:review-blocked" "orphaned-child:orphaned-parent" \
            "pool-died-twice:" "iron-law:"; do
  r="${pair%%:*}"; want="${pair#*:}"
  got=$(klass "$r")
  [ "$got" = "$want" ] && ok || bad "br_ladder_class '$r' must be '${want:-empty}', got '${got:-empty}'"
done
# THE RUNG ORDER, driven as the pure function it is: mechanical first, the fix
# round SECOND and by default, the rebuild only third.
[ "$(rung rebase-conflict 0 0)" = mechanical ]    && ok || bad "rung 1 of a branch park must be the mechanical one (got $(rung rebase-conflict 0 0))"
[ "$(rung rebase-conflict 1 0)" = fix-round ]     && ok || bad "after the mechanical rung the DEFAULT next rung is the fix round (got $(rung rebase-conflict 1 0))"
[ "$(rung rebase-conflict 1 1)" = rebuild-fresh ] && ok || bad "rebuild-fresh only after the fix round has run (got $(rung rebase-conflict 1 1))"
[ "$(rung ci-red 0 0)" = mechanical ]             && ok || bad "a red-CI park starts mechanical (re-run/merge main), not with a rebuild"
[ "$(rung ci-red 1 0)" = fix-round ]              && ok || bad "a red-CI park's second rung is the fix round"
[ "$(rung ci-red 1 1)" = rebuild-fresh ]          && ok || bad "a red-CI park reaches the rebuild only third"
# A review BLOCK skips rung 1: merging main answers nothing a reviewer asked.
[ "$(rung review-blocked 0 0)" = fix-round ]      && ok || bad "a review-blocked park must start at the fix round, not at a mechanical merge"
[ "$(rung review-blocked 0 1)" = rebuild-fresh ]  && ok || bad "a review-blocked park rebuilds only after its fix round"
# AN ORPHANED CHILD SKIPS RUNG 1 FOR THE SAME SHAPE OF REASON (2026-09-16). The
# PR this branch was cut from closed without merging, so the branch is carrying
# commits that will never land — and merging origin/main into it, which is all
# rung 1 does, takes not one of them out. The fix is a rebase, and that is the
# fix round's job. project-5 #1586/#1585/#1587 are the case.
[ "$(rung orphaned-parent 0 0)" = fix-round ]     && ok || bad "an orphaned-parent park must start at the fix round — a mechanical merge cannot unstack a dead parent (got $(rung orphaned-parent 0 0))"
[ "$(rung orphaned-parent 0 1)" = rebuild-fresh ] && ok || bad "and it reaches the rebuild only after that fix round (got $(rung orphaned-parent 0 1))"
bash -c '. "$0"; br_skips_mechanical review-blocked' "$T/cls.sh" \
  && ok || bad "br_skips_mechanical must still answer for review-blocked"
bash -c '. "$0"; br_skips_mechanical orphaned-parent' "$T/cls.sh" \
  && ok || bad "br_skips_mechanical must answer for orphaned-parent"
bash -c '. "$0"; br_skips_mechanical rebase-conflict' "$T/cls.sh" \
  && bad "a rebase-conflict park DOES get the mechanical rung — it is the cheapest thing that can fix it" || ok
# The park reason arrives with detail appended (the dead base branch and the
# parent's PR url), and the prefix match is what keeps that readable.
[ "$(bash -c '. "$0"; br_reason_of "$1"' "$T/cls.sh" 'orphaned-child: the PR this one is stacked on (ticket/TK-1529 (parent https://github.com/example-org/project-5/pull/1556 closed without merging; it still carries 2 commit(s))) closed without merging')" = orphaned-child ] \
  && ok || bad "a reason with the conductor's detail on it must still normalise to orphaned-child"
# With the ladder switched off it is still a fix round, never a close.
[ "$(bash -c 'BR_LADDER=0; . "$0"; br_action orphaned-child' "$T/cls.sh")" = fix-round ] \
  && ok || bad "BR_LADDER=0 must still answer fix-round for an orphaned child, not rebuild-fresh and never a close"
# THE FIX CAP IS AN ARGUMENT NOW, and the rung chosen has to agree with the rung
# that runs: br_one passes br_fix_cap and br_fix_round reads the same one, so a
# ticket with two rounds bought must not be sent to the rebuild after one.
[ "$(rung4 rebase-conflict 1 1 2)" = fix-round ]     && ok \
  || bad "with a fix cap of 2 a ticket that ran one round must get its second (got $(rung4 rebase-conflict 1 1 2))"
[ "$(rung4 rebase-conflict 1 2 2)" = rebuild-fresh ] && ok \
  || bad "and with both rounds spent it reaches the rebuild (got $(rung4 rebase-conflict 1 2 2))"
[ "$(rung4 rebase-conflict 1 1 '')" = rebuild-fresh ] && ok \
  || bad "an empty 4th argument must fall back to the default cap, never be read as 'unlimited'"
# A LOSER OF A CONTESTED PATH IS NEVER OFFERED TO THE LADDER. br_from_conductor
# drops a row whose reason br_reason_of cannot name, and that is what keeps a
# parked loser out of this lane entirely.
[ -z "$(bash -c '. "$0"; br_reason_of "$1"' "$T/cls.sh" 'contested:a.txt (winner TK-1529)')" ] && ok \
  || bad "a contested park must normalise to nothing, so the ladder never offers a loser a rung"
[ "$(cls 'contested:a.txt (winner TK-1529)')" = none ] && ok \
  || bad "and its action must be 'none' (got $(cls 'contested:a.txt (winner TK-1529)'))"
# And the caps are configuration, not constants.
[ "$(BR_MAX_MECHANICAL=0 rung ci-red 0 0)" = fix-round ] && ok || bad "BR_MAX_MECHANICAL=0 must skip the mechanical rung"
[ "$(BR_MAX_FIXROUNDS=2 rung ci-red 1 1)" = fix-round ]  && ok || bad "BR_MAX_FIXROUNDS=2 must buy a second fix round"
# The kill switch restores exactly the pre-ladder answers.
for pair in "conflict-unresolvable:rebuild-fresh" "red-twice:rebuild-fresh" \
            "head-not-reapproved:fix-round"; do
  r="${pair%%:*}"; want="${pair##*:}"
  got=$(BR_LADDER=0 raw "$r")
  [ "$got" = "$want" ] && ok || bad "BR_LADDER=0 must answer '$r' with $want, got '$got'"
done
# An unknown reason must NOT be rebuilt on a guess — it keeps today's behaviour
# (the conductor still pages) until somebody adds it deliberately.
[ "$(raw invented-tomorrow)" = none ] && ok || bad "an unknown reason must classify as 'none', never as an action"

echo "br-ladder-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
