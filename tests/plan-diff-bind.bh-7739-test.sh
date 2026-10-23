#!/bin/bash
# tests/plan-diff-bind.bh-7739-test.sh — plan-diff-bind on a merge-queue batch
# (BH-7739): the one plan in a batch is judged against its own member's diff.
#
#   M1  the ticket's case: member A (plan) and member B (no plan). No
#       changed-not-planned for B's bin/b.sh; stderr names A's sha12.
#   M2  the same batch, plan member merged first.
#   M3  a bound batch still bites: A's own planned-not-changed and
#       changed-not-planned fire, B's file does not.
#   M4  near miss: an ordinary PR with a "Merge origin/main" commit.
#   M5  near miss: a stack (own commit plus a merge of a sibling branch).
#   M6  the plan in 2 member diffs: skip.
#   M7  a batch of one: judged as on its own PR.
#   M8  a member that merged main inside its own branch: main's files are not
#       charged to it.
#   M4b near miss: all merges, the top one merges origin/main.
#   M9  a member behind the base: main's later files are not charged to it.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-diff-bind.bh-7739-test.sh
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
  mkdir -p "$R/bin/lib" "$R/worker/jobs/src/routes"
  for f in bin/a.sh bin/b.sh bin/m.sh bin/lib/flaky.sh worker/jobs/src/routes/flags.js; do
    echo "base $f" > "$R/$f"
  done
  rd_fixture_repo "$R" >/dev/null || { echo "FAIL: cannot build fixture $1"; exit 1; }
}
g() { rd_git "$R" "$@"; }
# branch <name> — a new branch off origin/main, checked out
branch() { g checkout -q -b "$1" refs/remotes/origin/main; }
plan() { mkdir -p "$R/.harness/specs/X"; cat > "$R/$PLANP"; }
plan_a() { printf '%s\n' '# X plan' '' '## Files to touch' '' '- `bin/a.sh`: the change.' | plan; }
change() { local f; for f; do mkdir -p "$R/$(dirname "$f")"; echo "change $f" >> "$R/$f"; done; }
# change_m <repo> — main's own edit, for rd_main_commit
change_m() { echo "main" >> "$1/bin/m.sh"; }
commit() { g add -A && g commit -qm "${1:-c}"; }
# draft <branch...> — reset work to origin/main and merge each branch --no-ff,
# in order, the way a Mergify batch draft does
draft() {
  local b n=1
  g checkout -q work && g reset -q --hard refs/remotes/origin/main || return 1
  for b; do g merge -q --no-ff -m "Merge of #$n" "$b" >/dev/null || return 1; n=$((n + 1)); done
}
check() { run bash "$PDB" --base origin/main "$R"; }
sha12() { g rev-parse "$1" | cut -c1-12; }
has() {
  printf '%s\n' "$OUT" | awk -v p="$2" 'index($0, p) == 1 { f = 1 } END { exit !f }' && ok \
    || bad "$1 stdout [$OUT] (want a line starting [$2])"
}
lines() { local n; n=$(grep -c . <<<"$OUT"); [ "$n" -eq "$2" ] && ok || bad "$1 $n finding lines (want $2): $OUT"; }
rc_is() { [ "$RC" -eq "$2" ] && ok || bad "$1 rc $RC (want $2): $OUT $ERR"; }
clean() { rc_is "$1" 0; [ -z "$OUT" ] && ok || bad "$1 stdout [$OUT] (want empty)"; }
err_has() { grep -qxF -- "$2" <<<"$ERR" && ok || bad "$1 stderr [$ERR] (want the line [$2])"; }
no_b() { grep -q 'bin/b\.sh' <<<"$OUT" && bad "$1 a finding for B's bin/b.sh: $OUT" || ok; }

# ── M1: the ticket's case ─────────────────────────────────────────────────
new_repo m1
branch a; plan_a; change bin/a.sh; commit A
branch b; change bin/b.sh; commit B
draft b a || bad "M1 cannot build the draft"
check
clean M1
no_b M1
err_has M1 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── M2: plan member merged first ──────────────────────────────────────────
new_repo m2
branch a; plan_a; change bin/a.sh; commit A
branch b; change bin/b.sh; commit B
draft a b || bad "M2 cannot build the draft"
check
clean M2
no_b M2
err_has M2 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── M3: the binding still bites on the member's own diff ──────────────────
new_repo m3
branch a
printf '%s\n' '# X plan' '' '## Files to touch' '' '- `bin/a.sh`: the change.' \
  '- `worker/jobs/src/routes/flags.js`: the route.' | plan
change bin/a.sh bin/lib/flaky.sh; commit A
branch b; change bin/b.sh; commit B
draft b a || bad "M3 cannot build the draft"
check
rc_is M3 1
lines M3 2
has M3 "planned-not-changed worker/jobs/src/routes/flags.js $PLANP:6 — "
has M3 "changed-not-planned bin/lib/flaky.sh $PLANP — "
no_b M3
err_has M3 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── M4: near miss, an ordinary PR that merged origin/main ─────────────────
new_repo m4
plan_a; change bin/a.sh bin/b.sh; commit own
rd_main_commit "$R" main-moves change_m || bad "M4 cannot move main"
g merge -q --no-ff -m "Merge origin/main into work" refs/remotes/origin/main >/dev/null || bad "M4 cannot merge main"
check
rc_is M4 1
lines M4 1
has M4 "changed-not-planned bin/b.sh $PLANP — "
grep -q 'batch' <<<"$ERR" && bad "M4 read as a batch: $ERR" || ok

# M4b near miss: every first-parent commit is a merge, but the top one merges
#     origin/main (its second parent is in the base). Not a batch.
new_repo m4b
branch f; plan_a; change bin/a.sh bin/b.sh; commit F
g checkout -q work
g merge -q --no-ff -m "Merge f" f >/dev/null || bad "M4b cannot merge f"
rd_main_commit "$R" main-moves change_m || bad "M4b cannot move main"
g merge -q --no-ff -m "Merge origin/main into work" refs/remotes/origin/main >/dev/null || bad "M4b cannot merge main"
check
rc_is M4b 1
lines M4b 1
has M4b "changed-not-planned bin/b.sh $PLANP — "
grep -q 'batch' <<<"$ERR" && bad "M4b read as a batch: $ERR" || ok

# ── M5: near miss, a stack ────────────────────────────────────────────────
new_repo m5
branch sib; change bin/b.sh; commit sibling
g checkout -q work
plan_a; change bin/a.sh; commit own
g merge -q --no-ff -m "Merge sib" sib >/dev/null || bad "M5 cannot merge the sibling"
check
rc_is M5 1
lines M5 1
has M5 "changed-not-planned bin/b.sh $PLANP — "
grep -q 'batch' <<<"$ERR" && bad "M5 read as a batch: $ERR" || ok

# ── M6: the plan in 2 member diffs ────────────────────────────────────────
new_repo m6
branch a; plan_a; change bin/a.sh; commit A
branch b; plan_a; change bin/b.sh; commit B
draft a b || bad "M6 cannot build the draft"
check
clean M6
err_has M6 "plan-diff-bind: skip (batch: $PLANP in 2 of 2 members)"

# ── M7: a batch of one is judged as on its own PR ─────────────────────────
new_repo m7
branch a; plan_a; change bin/a.sh bin/b.sh; commit A
draft a || bad "M7 cannot build the draft"
check
rc_is M7 1
lines M7 1
has M7 "changed-not-planned bin/b.sh $PLANP — "
err_has M7 "plan-diff-bind: batch of 1 members, $PLANP bound to member $(sha12 a) only"

# ── M8: a member that merged main inside its own branch ───────────────────
new_repo m8
branch a; plan_a; change bin/a.sh; commit A
g checkout -q work
rd_main_commit "$R" main-moves change_m || bad "M8 cannot move main"
g checkout -q a
g merge -q --no-ff -m "Merge origin/main into a" refs/remotes/origin/main >/dev/null || bad "M8 cannot merge main into a"
branch b; change bin/b.sh; commit B
draft a b || bad "M8 cannot build the draft"
check
clean M8
no_b M8
grep -q 'bin/m\.sh' <<<"$OUT" && bad "M8 main's bin/m.sh charged to A: $OUT" || ok
err_has M8 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

# ── M9: a member behind the base: main's later files are not charged to it ─
new_repo m9
branch a; plan_a; change bin/a.sh; commit A
g checkout -q work
rd_main_commit "$R" main-moves change_m || bad "M9 cannot move main"
branch b; change bin/b.sh; commit B
draft a b || bad "M9 cannot build the draft"
check
clean M9
grep -q 'bin/m\.sh' <<<"$OUT" && bad "M9 main's bin/m.sh charged to A: $OUT" || ok
err_has M9 "plan-diff-bind: batch of 2 members, $PLANP bound to member $(sha12 a) only"

echo "plan-diff-bind batch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
