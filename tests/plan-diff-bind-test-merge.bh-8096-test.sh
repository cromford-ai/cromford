#!/bin/bash
# tests/plan-diff-bind-test-merge.bh-8096-test.sh — plan-diff-bind under
# GitHub's test merge (BH-8096). A `pull_request` lint checkout is the 2-parent
# commit `Merge <PR head> into <base>`; the check judges the PR head instead.
#
#   P1  the ticket's case: a 2-member draft (A adds the plan, B changes
#       bin/b.sh) under the test merge. rc 0, the unwrap line, A bound.
#   P2  the same, plan member merged last (the #8101 shape).
#   P3  a stacked draft (draft 2 = draft 1 plus a merge of B).
#   P4  it still bites: A's own unplanned bin/z.sh fires, B's file does not.
#   N1  an ordinary PR under the test merge: same rc and stdout as on its head.
#   N2  `Merge branch 'main' into a` (not sha-shaped): no unwrap.
#   N3  abbreviated shas in the subject: no unwrap.
#   N4  the shas swapped: no unwrap.
#   N5  a 1-parent commit with the test-merge subject: no unwrap.
#   N6  a 3-parent octopus with the test-merge subject: no unwrap.
# N3-N6 wrap a P1-shaped draft, so a wrong unwrap turns their rc 1 into rc 0.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-diff-bind-test-merge.bh-8096-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1
mkdir -p "$T/inst"
( cd "$DIR" && scratch_install_closure bin/lib/plan-diff-bind.sh "$T/inst" ) >/dev/null \
  || bad "cannot install bin/lib/plan-diff-bind.sh"
PDB="$T/inst/bin/lib/plan-diff-bind.sh"
PLANP=.harness/specs/X/plan.md

run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
new_repo() {
  R="$T/$1"
  mkdir -p "$R/bin"
  for f in bin/a.sh bin/b.sh bin/m.sh; do echo "base $f" > "$R/$f"; done
  rd_fixture_repo "$R" >/dev/null || { echo "FAIL: cannot build fixture $1"; exit 1; }
}
g() { rd_git "$R" "$@"; }
branch() { g checkout -q -b "$1" refs/remotes/origin/main; }
plan_a() { mkdir -p "$R/.harness/specs/X"; printf '%s\n' '# X plan' '' '## Files to touch' '' '- `bin/a.sh`: the change.' > "$R/$PLANP"; }
change() { local f; for f; do mkdir -p "$R/$(dirname "$f")"; echo "change $f" >> "$R/$f"; done; }
change_m() { echo "main" >> "$1/bin/m.sh"; }
commit() { g add -A && g commit -qm "${1:-c}"; }
# draft <branch...> — reset work to origin/main and merge each branch --no-ff,
# in order, the way a Mergify batch draft does
draft() {
  local b n=1
  g checkout -q work && g reset -q --hard refs/remotes/origin/main || return 1
  for b; do g merge -q --no-ff -m "Merge of #$n" "$b" >/dev/null || return 1; n=$((n + 1)); done
}
full() { g rev-parse "$1"; }
sha12() { full "$1" | cut -c1-12; }
# test_merge <rev> [subject] — GitHub's refs/pull/<n>/merge: origin/main,
# detached, merged --no-ff with <rev>, subject `Merge <rev> into <main>`
test_merge() {
  local h m
  h=$(full "$1") && m=$(full refs/remotes/origin/main) || return 1
  g checkout -q --detach "$m" || return 1
  g merge -q --no-ff -m "${2:-Merge $h into $m}" "$h" >/dev/null
}
check() { run bash "$PDB" --base origin/main "$R"; }
has() {
  printf '%s\n' "$OUT" | awk -v p="$2" 'index($0, p) == 1 { f = 1 } END { exit !f }' && ok \
    || bad "$1 stdout [$OUT] (want a line starting [$2])"
}
lines() { local n; n=$(grep -c . <<<"$OUT"); [ "$n" -eq "$2" ] && ok || bad "$1 $n finding lines (want $2): $OUT"; }
rc_is() { [ "$RC" -eq "$2" ] && ok || bad "$1 rc $RC (want $2): $OUT $ERR"; }
clean() { rc_is "$1" 0; [ -z "$OUT" ] && ok || bad "$1 stdout [$OUT] (want empty)"; }
err_has() { grep -qxF -- "$2" <<<"$ERR" && ok || bad "$1 stderr [$ERR] (want the line [$2])"; }
no_b() { grep -q 'bin/b\.sh' <<<"$OUT" && bad "$1 a finding for B's bin/b.sh: $OUT" || ok; }
no_unwrap() { grep -q 'is the PR test merge' <<<"$ERR" && bad "$1 unwrapped a non-test-merge HEAD: $ERR" || ok; }
unwrap_line() { echo "plan-diff-bind: HEAD $(sha12 HEAD) is the PR test merge, judging the PR head $(sha12 "$1")"; }
# p1_draft <order...> — members a (plan + bin/a.sh) and b (bin/b.sh), draft on work
p1_draft() {
  branch a; plan_a; change bin/a.sh; commit A
  branch b; change bin/b.sh; commit B
  draft "$@"
}
# false_red <case> — the result of the check on a P1 draft it does not unwrap
false_red() { rc_is "$1" 1; has "$1" "changed-not-planned bin/b.sh $PLANP — "; no_unwrap "$1"; }

# ── P1: the ticket's case ─────────────────────────────────────────────────
new_repo p1
p1_draft a b || bad "P1 cannot build the draft"
test_merge work || bad "P1 cannot build the test merge"
check
clean P1
no_b P1
err_has P1 "$(unwrap_line work)"
err_has P1 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── P2: plan member merged last ───────────────────────────────────────────
new_repo p2
p1_draft b a || bad "P2 cannot build the draft"
test_merge work || bad "P2 cannot build the test merge"
check
clean P2
no_b P2
err_has P2 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── P3: a stacked draft ───────────────────────────────────────────────────
new_repo p3
branch a; plan_a; change bin/a.sh; commit A
branch b; change bin/b.sh; commit B
g checkout -q -b d1 refs/remotes/origin/main
g merge -q --no-ff -m "Merge of #1" a >/dev/null || bad "P3 cannot build draft 1"
g checkout -q -b d2 d1
g merge -q --no-ff -m "Merge of #2" b >/dev/null || bad "P3 cannot build draft 2"
test_merge d2 || bad "P3 cannot build the test merge"
check
clean P3
no_b P3
err_has P3 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── P4: the bound check still bites on the member's own file ──────────────
new_repo p4
branch a; plan_a; change bin/a.sh bin/z.sh; commit A
branch b; change bin/b.sh; commit B
draft b a || bad "P4 cannot build the draft"
test_merge work || bad "P4 cannot build the test merge"
check
rc_is P4 1
lines P4 1
has P4 "changed-not-planned bin/z.sh $PLANP — "
no_b P4

# ── N1: an ordinary PR reads the same under the test merge ────────────────
new_repo n1
plan_a; change bin/a.sh bin/z.sh; commit own
check; RC0=$RC; OUT0=$OUT
test_merge work || bad "N1 cannot build the test merge"
check
rc_is N1 1
[ "$RC0" -eq "$RC" ] && [ "$OUT0" = "$OUT" ] && ok || bad "N1 test merge rc $RC [$OUT], PR head rc $RC0 [$OUT0]"
lines N1 1
has N1 "changed-not-planned bin/z.sh $PLANP — "
err_has N1 "$(unwrap_line work)"

# ── N2: `Merge branch 'main' into a` is not the test merge ────────────────
new_repo n2
plan_a; change bin/a.sh bin/b.sh; commit own
rd_main_commit "$R" main-moves change_m || bad "N2 cannot move main"
g merge -q --no-ff -m "Merge branch 'main' into a" refs/remotes/origin/main >/dev/null || bad "N2 cannot merge main"
check
rc_is N2 1
lines N2 1
has N2 "changed-not-planned bin/b.sh $PLANP — "
no_unwrap N2

# ── N3: abbreviated shas ──────────────────────────────────────────────────
new_repo n3
p1_draft b a || bad "N3 cannot build the draft"
test_merge work "Merge $(sha12 work) into $(sha12 refs/remotes/origin/main)" || bad "N3 cannot build the merge"
check
false_red N3

# ── N4: the shas swapped ──────────────────────────────────────────────────
new_repo n4
p1_draft b a || bad "N4 cannot build the draft"
test_merge work "Merge $(full refs/remotes/origin/main) into $(full work)" || bad "N4 cannot build the merge"
check
false_red N4

# ── N5: one parent, the test-merge subject ────────────────────────────────
new_repo n5
p1_draft b a || bad "N5 cannot build the draft"
D=$(full work); M=$(full refs/remotes/origin/main)
g checkout -q --detach "$M" && g merge -q --squash "$D" >/dev/null && g commit -qm "Merge $D into $M" \
  || bad "N5 cannot build the squash"
[ "$(g rev-list --parents -n1 HEAD | wc -w)" -eq 2 ] && ok || bad "N5 HEAD is not a 1-parent commit"
check
rc_is N5 1
has N5 "changed-not-planned bin/b.sh $PLANP — "
no_unwrap N5

# ── N6: a 3-parent octopus, the test-merge subject ────────────────────────
new_repo n6
branch a; plan_a; change bin/a.sh; commit A
branch b; change bin/b.sh; commit B
A=$(full a); M=$(full refs/remotes/origin/main)
g checkout -q --detach "$M" && g merge -q --no-ff -m "Merge $A into $M" a b >/dev/null \
  || bad "N6 cannot build the octopus"
[ "$(g rev-list --parents -n1 HEAD | wc -w)" -eq 4 ] && ok || bad "N6 HEAD is not a 3-parent commit"
check
rc_is N6 1
has N6 "changed-not-planned bin/b.sh $PLANP — "
no_unwrap N6

echo "plan-diff-bind test merge: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
