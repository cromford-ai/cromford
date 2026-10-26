#!/bin/bash
# tests/pr-self-check-test-ownership.bh-6392-test.sh — BH-6392: a test belongs
# to its ticket (D51, enforced). The pre-review self-check (bin/pr-self-check.sh,
# bin/lib/pr-self-check.sh, rule `test-ownership` in catalog/pr-self-check.tsv)
# refuses a PR that edits or deletes tests/*.<other-key>-test.sh with no
# `TEST-CHANGE:` line in the body that names the file and the premise. The PR
# body composer (bin/lib/rb/pr.sh PR_BODY_FOR) carries those lines from the
# plan's `## Tests that must change` and the commit messages
# (psc_test_change_section), and the planner sentence (bin/lib/test-home-lib.sh
# th_plan_rule) asks for that section. lgsc_run (bin/lib/lead-gates-selfcheck.sh)
# passes the PR title key as PSC_PR_KEY; K1-K3 of
# tests/lead-gates-selfcheck-key.bh-8363-test.sh pin that.
#
#   O1  BH-200 edits tests/x.bh-100-test.sh, no line: REFUSE, rc 1
#   O2  same, a line names the path and a premise: pass
#   O3  BH-200 adds tests/z.bh-200-test.sh: silent
#   O4  an edit to tests/plain-test.sh (no key): silent
#   T1  the line names the basename and a premise: pass
#   T2  the line names another file: REFUSE
#   T3  the line names the file and no premise: REFUSE, says no premise
#   T4  BH-200 deletes tests/x.bh-100-test.sh, no line: REFUSE
#   K1  --key BH-200 over a body with no key: REFUSE; --key BH-100: pass
#   K2  the Harness-Ticket: BH-200 trailer decides the key
#   K3  no key anywhere: one NOTE, rc 0
#   K4  slice BH-100.2 edits a bh-100 test: own test, pass
#   K5  the one .harness/specs/BH-200/plan.md in the diff decides the key
#   N1  tests/agent-call-call-guard.k3-test.sh and bin/foo.bh-100-test.sh: silent
#   S1  a diff with no test file: no test-ownership text at all
#   M1  the row set to `off`: O1 passes
#   B1-B4  psc_test_change_section: plan lines, commit lines, dedup, None
#   R1  B1+B2 output as the body passes; drop one line and it refuses that file
#   P1  th_plan_rule names `## Tests that must change` and TEST-CHANGE
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-self-check-test-ownership.bh-6392-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PSC_PR_KEY
H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
cp "$DIR/catalog/pr-self-check.tsv" "$T/catalog.tsv" 2>/dev/null || : > "$T/catalog.tsv"
export PR_SELF_CHECK_ONLY='^test-ownership$'

R="$T/repo"; mkdir -p "$R/tests"
git -C "$R" init -q -b main
echo a > "$R/tests/x.bh-100-test.sh"; echo a > "$R/tests/plain-test.sh"; echo a > "$R/tests/y.bh-200-test.sh"
echo a > "$R/tests/agent-call-call-guard.k3-test.sh"; mkdir -p "$R/bin"; echo a > "$R/bin/a.sh"
git -C "$R" add -A; git -C "$R" commit -qm M0
# branch <name> <cmd...>: a branch off main where the commands run in the repo
branch() {
  local b="$1"; shift
  git -C "$R" checkout -q main; git -C "$R" checkout -qb "$b"
  ( cd "$R" && eval "$*" )
  git -C "$R" add -A; git -C "$R" commit -qm "$b"
}
check() { # check <head> <body-text> [extra args] — sets RC and OUT
  local h="$1" b="$2"; shift 2
  printf '%s\n' "$b" > "$T/body.md"
  OUT=$(PR_SELF_CHECK_CATALOG="${CAT:-$T/catalog.tsv}" bash "$H/bin/pr-self-check.sh" check \
          --repo "$R" --base main --head "$h" --body "$T/body.md" "$@" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

branch o1 'echo b >> tests/x.bh-100-test.sh'
branch o3 'echo z > tests/z.bh-200-test.sh'
branch o4 'echo b >> tests/plain-test.sh'
branch t4 'git rm -q tests/x.bh-100-test.sh'
branch k5 'mkdir -p .harness/specs/BH-200 && echo plan > .harness/specs/BH-200/plan.md && echo b >> tests/x.bh-100-test.sh'
branch n1 'echo b >> tests/agent-call-call-guard.k3-test.sh; echo b > bin/foo.bh-100-test.sh'
branch s1 'echo b >> bin/a.sh'
branch r1 'echo b >> tests/x.bh-100-test.sh; echo b >> tests/y.bh-200-test.sh'

# ── O1-O4 ──
check o1 $'Ticket BH-200 — t\n\n## Why\nbecause'
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && has "tests/x.bh-100-test.sh" && ok || bad "O1: another ticket's test edited with no line must refuse (rc=$RC) [$OUT]"
check o1 $'Ticket BH-200 — t\n\nTEST-CHANGE: tests/x.bh-100-test.sh — the floor moved from 5 to 3 minutes'
[ "$RC" = 0 ] && ! has "REFUSE test-ownership" && ok || bad "O2: a line with the path and a premise passes (rc=$RC) [$OUT]"
check o3 $'Ticket BH-200 — t'
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "O3: an added test is never checked (rc=$RC) [$OUT]"
check o4 $'Ticket BH-200 — t'
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "O4: a test with no key is never checked (rc=$RC) [$OUT]"

# ── T1-T4 ──
check o1 $'Ticket BH-200 — t\n\n- `TEST-CHANGE: x.bh-100-test.sh` — the floor moved to three minutes'
[ "$RC" = 0 ] && ok || bad "T1: the basename and a premise pass (rc=$RC) [$OUT]"
check o1 $'Ticket BH-200 — t\n\nTEST-CHANGE: tests/other.bh-9-test.sh — the floor moved from 5 to 3 minutes'
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && ok || bad "T2: a line for another file does not cover it (rc=$RC) [$OUT]"
check o1 $'Ticket BH-200 — t\n\nTEST-CHANGE: tests/x.bh-100-test.sh'
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && has "no premise" && ok || bad "T3: a line with no premise refuses and says so (rc=$RC) [$OUT]"
check t4 $'Ticket BH-200 — t'
[ "$RC" = 1 ] && has "tests/x.bh-100-test.sh" && ok || bad "T4: a deleted test of another ticket refuses (rc=$RC) [$OUT]"

# ── K1-K5: the PR's own key ──
check o1 $'no key here\n\n## Why\nbecause' --key BH-200
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && ok || bad "K1: --key BH-200 decides the owner (rc=$RC) [$OUT]"
check o1 $'no key here' --key BH-100
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "K1: --key BH-100 owns the test (rc=$RC) [$OUT]"
check o1 $'no key here\n\nHarness-Ticket: BH-200'
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && ok || bad "K2: the Harness-Ticket trailer gives the key (rc=$RC) [$OUT]"
check o1 $'no key here\n\nHarness-Ticket: none'
[ "$RC" = 0 ] && [ "$(grep -c '^NOTE test-ownership:' <<<"$OUT")" = 1 ] && ! has "REFUSE" && ok || bad "K3: no key gives one NOTE and no refusal (rc=$RC) [$OUT]"
check o1 $'Ticket BH-100.2 — a slice'
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "K4: a slice owns its parent ticket's test (rc=$RC) [$OUT]"
check k5 $'no key here'
[ "$RC" = 1 ] && has "REFUSE test-ownership:" && ok || bad "K5: the one spec path gives the key (rc=$RC) [$OUT]"

# ── N1, S1, M1 ──
check n1 $'Ticket BH-200 — t'
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "N1: a k3 name and a bin/ path are not checked (rc=$RC) [$OUT]"
check s1 $'Ticket BH-200 — t'
! has "test-ownership" && ok || bad "S1: no test file, no test-ownership text (rc=$RC) [$OUT]"
sed 's/^test-ownership\trefuse\t/test-ownership\toff\t/' "$T/catalog.tsv" > "$T/catalog-off.tsv"
grep -q $'^test-ownership\toff\t' "$T/catalog-off.tsv" && ok || bad "M1: the catalog has no test-ownership refuse row to turn off"
CAT="$T/catalog-off.tsv" check o1 $'Ticket BH-200 — t'
[ "$RC" = 0 ] && ok || bad "M1: the row off passes O1 (rc=$RC) [$OUT]"

# ── B1-B4: the PR body bridge ──
section() { # section <plan-text> <commit-msg|-> — sets SEC
  git -C "$R" checkout -q main; git -C "$R" branch -qD bb 2>/dev/null; git -C "$R" checkout -qb bb
  if [ "$2" != - ]; then echo c >> "$R/bin/a.sh"; git -C "$R" commit -qam "$2"; fi
  printf '%s\n' "$1" > "$T/plan.md"
  SEC=$( cd "$R" && . "$H/bin/lib/pr-self-check.sh" && psc_test_change_section "$T/plan.md" main )
}
PLAN1=$'# plan\n\n## Tests that must change\n\n- `tests/x.bh-100-test.sh`: the floor moved\n\n## Tasks\n- `tests/q.bh-1-test.sh`: not this section'
section "$PLAN1" -
grep -qx '## Test changes' <<<"$SEC" && grep -qxF 'TEST-CHANGE: tests/x.bh-100-test.sh — the floor moved' <<<"$SEC" \
  && ! grep -q 'q.bh-1' <<<"$SEC" && ok || bad "B1: the plan section becomes TEST-CHANGE lines [$SEC]"
section $'# plan\n\n## Tests that must change\n\nNone' $'fix: x\n\nTEST-CHANGE: tests/y.bh-200-test.sh — the retired case is gone'
grep -qxF 'TEST-CHANGE: tests/y.bh-200-test.sh — the retired case is gone' <<<"$SEC" && ok || bad "B2: a commit line is copied verbatim [$SEC]"
section "$PLAN1" $'fix: x\n\nTEST-CHANGE: tests/x.bh-100-test.sh — another reason entirely'
[ "$(grep -c 'tests/x.bh-100-test.sh' <<<"$SEC")" = 1 ] && grep -q 'the floor moved' <<<"$SEC" && ok || bad "B3: one line per path, the plan wins [$SEC]"
section $'# plan\n\n## Tests that must change\n\nNone' -
[ -z "$SEC" ] && ok || bad "B4: None and no commit line print nothing [$SEC]"

# ── R1: the round trip ──
section "$PLAN1" $'fix: x\n\nTEST-CHANGE: tests/y.bh-200-test.sh — the retired case is gone'
check r1 "Ticket BH-300 — t
$SEC"
[ "$RC" = 0 ] && ! has "REFUSE test-ownership" && ok || bad "R1: the bridge output as the body passes (rc=$RC) [$OUT]"
check r1 "Ticket BH-300 — t
$(grep -v 'y.bh-200' <<<"$SEC")"
[ "$RC" = 1 ] && has "tests/y.bh-200-test.sh" && ! grep -q 'REFUSE.*x.bh-100' <<<"$OUT" && ok || bad "R1: drop the y line and it refuses y only (rc=$RC) [$OUT]"

# ── R2: the real composer (bin/lib/rb/pr.sh: the lib source line and the
#    evidence block's PR_BODY_FOR) renders a body the check passes ──
RB="$DIR/bin/lib/rb/pr.sh"
awk '/^# BH-6392: psc_test_change_section/{f=1} /^# >>> evidence block/{f=0} f' "$RB" > "$T/rb-src.sh"
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB" > "$T/evblock.sh"
git -C "$R" checkout -q r1; git -C "$R" checkout -qb r2
echo c >> "$R/bin/a.sh"; git -C "$R" commit -qam $'fix: y\n\nTEST-CHANGE: tests/y.bh-200-test.sh — the retired case is gone'
git -C "$R" update-ref refs/remotes/origin/main main
mkdir -p "$T/build"; printf '%s\n' "$PLAN1" > "$T/build/plan.md"
BODY=$( cd "$R" && env PATH="$PATH" HARNESS="$H" BUILD="$T/build" bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    . "$0"
    PROJECT=p; KEY=BH-300; BASE=main; CHANGED="x"; PR_SUBJECT="t"
    TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; E2E_VERDICT=pass; ADDED_SQL=""; MIG_NOTE=""
    WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
    PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
    CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; STACK_SECTION=""; MERGE_NOTE=""
    . "$1" >/dev/null 2>&1
    ASSUMPTIONS_SECTION=""
    PR_BODY_FOR "EVIDENCE"' "$T/rb-src.sh" "$T/evblock.sh" 2>/dev/null )
grep -qx '## Test changes' <<<"$BODY" && grep -qF 'TEST-CHANGE: tests/y.bh-200-test.sh — the retired case is gone' <<<"$BODY" \
  && grep -qF 'TEST-CHANGE: tests/x.bh-100-test.sh — the floor moved' <<<"$BODY" && ok || bad "R2: PR_BODY_FOR must carry the ## Test changes lines [$BODY]"
check r2 "$BODY"
[ "$RC" = 0 ] && ! has "test-ownership" && ok || bad "R2: the composed body passes test-ownership (rc=$RC) [$OUT]"

# ── P1: the planner sentence ──
P=$( . "$DIR/bin/lib/test-home-lib.sh" && th_plan_rule AB-1 )
case "$P" in "TEST FILES ARE PER-TICKET"*) ok ;; *) bad "P1: th_plan_rule must start with TEST FILES ARE PER-TICKET" ;; esac
grep -qF '## Tests that must change' <<<"$P" && grep -qF 'TEST-CHANGE' <<<"$P" && ok || bad "P1: th_plan_rule names the section and TEST-CHANGE [$P]"
P2=$( . "$DIR/bin/lib/test-home-lib.sh" && th_plan_rule AB-1; echo x )
case "$P2" in *[!\ ]" x") ok ;; *) bad "P1: th_plan_rule must end in exactly one space" ;; esac

echo "pr-self-check-test-ownership.bh-6392: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
