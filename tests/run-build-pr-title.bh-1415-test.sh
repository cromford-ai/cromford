#!/bin/bash
# tests/run-build-pr-title.bh-1415-test.sh — the PR a build opens is named after
# the TICKET, and its `## What` lists only the commits this branch added.
#
# THE INCIDENT (BH-1415, the 2026-09-22 pool wave, 33 PRs #1376-#1414). The spec
# artifact stage commits `spec(<KEY>): the plan this build was executed from`
# AFTER execute, so HEAD is that commit when the PR is opened — and the title was
# `git log -1 --format=%s`. Every PR in the wave was called
# `BH-<n>: spec(BH-<n>): the plan this build was executed from`. The `## What`
# list had the sibling defect: it diffed against the LOCAL `main` ref, which the
# pre-PR rebase onto `origin/main` leaves behind, so the body listed
# `merge train: …`, `train: #…` and other tickets' commits as this branch's work.
#
# The two production blocks are extracted VERBATIM by their markers and driven
# in a scratch git repo shaped exactly like the incident (a branch rebased onto a
# moved origin/main, with the local `main` ref left at the old tip), the way
# tests/pr-body-closes-test.sh and tests/evidence-block-test.sh drive the
# evidence block. Case 7 drives the PRODUCTION ENTRY POINT: the real
# `# >>> pr create ladder` block, whose `--title "$KEY: $PR_SUBJECT"` argument is
# captured off a stubbed gh_pr_create_ladder — deleting the title block from the
# driver takes that case red, not only the unit cases.
#
# Run from anywhere: tests/run-build-pr-title.bh-1415-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/build" "$T/repo" "$T/out"
# The evidence block's CLOSE_ISSUE_AFTER_MERGE writes through this library, which
# bin/run-build.sh sources at the top.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Extraction is guarded, never assumed (D3): a marker that moved must fail the
# suite here rather than silently drive an empty block that asserts nothing.
extract() { # extract <marker name> <out file>
  awk -v s="^# >>> $1" -v e="^# <<< $1" '$0 ~ s {f=1;next} $0 ~ e {exit} f' "$RB_ALL" > "$2"
  [ -s "$2" ]
}
extract "pr what list"      "$T/whatlist.sh"  && ok || bad "no '# >>> pr what list' block in bin/run-build.sh — the What list still reads \$BASE..HEAD"
extract "pr title subject"  "$T/title.sh"     && ok || bad "no '# >>> pr title subject' block in bin/run-build.sh — the title is still git log -1"
extract "merge note fn"     "$T/mergenote.sh" && ok || bad "could not extract the merge note fn block — markers moved?"
extract "evidence block"    "$T/evidence.sh"  && ok || bad "could not extract the evidence block — markers moved?"
extract "pr create ladder"  "$T/ladder.sh"    && ok || bad "could not extract the pr create ladder block — markers moved?"
hold_gate_prepend "$RB_ALL" "$T/ladder.sh"   # BH-6091: the real gate, a no-HOLD ticket read

# ── the scratch repo: the incident's exact shape ─────────────────────────────
# A: the old main. origin/main then gains the train commits and another ticket's
# merge; the branch is rebased onto that tip and adds its own commit plus the
# spec commit; the LOCAL main ref stays at A, which is what the pre-PR rebase
# leaves behind on a pool machine.
git init -q -b main "$T/repo" >/dev/null 2>&1
(
  cd "$T/repo" || exit 1
  git config user.email t@example.com; git config user.name t
  git config commit.gpgsign false
  # The subject is the file content too, so every commit differs without a clock
  # or a random number (bin/test-determinism-lint.sh).
  C() { echo "$1" > f.txt; git add -A; git -c commit.gpgsign=false commit -qm "$1"; }
  C "BH-0: the base commit"
  git checkout -q -b mainline
  C "merge train: 1 approved PRs (#1432)"
  C "train: #1422"
  C "BH-1313: gh-pr-merge picks the merge method from the repo's settings"
  git update-ref refs/remotes/origin/main refs/heads/mainline
  git checkout -q -b ticket/bh-1415 mainline
  C "BH-1415: derive the PR title from ticket meta"
  C "spec(BH-1415): the plan this build was executed from"
  # 4b: a branch that genuinely carries a train-shaped subject of its own.
  git checkout -q -b ticket/bh-own mainline
  C "train: #9 the branch's own commit"
  C "BH-1415: a second subject"
  git checkout -q ticket/bh-1415
) >/dev/null 2>&1

TITLE='PR title/body generator: title is the spec commit and What lists main'"'"'s train commits (33-PR wave 2026-09-22)'
meta() { jq -nc --arg t "$1" '{title:$t}' > "$T/build/ticket-meta.json"; }
nometa() { rm -f "$T/build/ticket-meta.json"; }

# drive <source-list> [env...] — sources the named blocks in production order in
# a shell holding the variables run-build.sh holds at that point, and dumps what
# the blocks produced into $T/out.
drive() { # drive "<block files>" [VAR=val...]
  local blocks="$1"; shift
  : > "$T/build/pipeline.log"; rm -f "$T/out"/*
  ( cd "$T/repo" || exit 1
    env HARNESS="$T" BUILD="$T/build" OUT="$T/out" BLOCKS="$blocks" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=bh; SLUG=o/r; KEY=${KEY:-BH-1415}; BASE=${BASE:-main}; TIER=1
      BRANCH=ticket/bh-1415; PCF_SLUG=o/r
      QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="f.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST=""; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      GH_ERR_AT=0
      job_evidence_put() { return 0; }
      GH_LIVE() { return 0; }
      # The stub stands in for bin/lib/gh-pr-create.sh: one argument per line, so
      # the title argument is read exactly as the ladder passed it.
      gh_pr_create_ladder() {
        printf "%s\n" "$@" > "$OUT/ladder-argv.txt"
        echo "https://github.com/o/r/pull/9"
      }
      for b in $BLOCKS; do . "$b" || exit 1; done
      printf "%s" "${WHAT_LIST:-}"  > "$OUT/what.txt"
      printf "%s" "${PR_SUBJECT:-}" > "$OUT/subject.txt"
      if declare -f PR_BODY_FOR >/dev/null 2>&1; then
        printf "%s" "$(PR_BODY_FOR "${EVIDENCE_SECTION:-}")" > "$OUT/body.txt"
      fi
    ' bh 2>"$T/err.txt" )
}

W="$T/whatlist.sh"; TI="$T/title.sh"; MN="$T/mergenote.sh"; EV="$T/evidence.sh"; LA="$T/ladder.sh"

# 1. ticket-meta.json present: the subject is the TICKET title, key prefix not doubled
meta "$TITLE"
drive "$TI"
[ "$(cat "$T/out/subject.txt")" = "${TITLE:0:80}" ] \
  && ok || bad "1: PR_SUBJECT is not the ticket title (truncated to 80): got '$(cat "$T/out/subject.txt")' err=$(cat "$T/err.txt")"
case "$(cat "$T/out/subject.txt")" in
  *"spec(BH-1415)"*) bad "1: the spec commit subject reached the title" ;;
  *) ok ;;
esac

# 2. no ticket-meta.json: the newest NON-spec commit subject, with the key prefix
#    stripped so the created title is not "BH-1415: BH-1415: …"
nometa
drive "$TI"
[ "$(cat "$T/out/subject.txt")" = "derive the PR title from ticket meta" ] \
  && ok || bad "2: fallback subject is not the newest non-spec commit subject: got '$(cat "$T/out/subject.txt")' err=$(cat "$T/err.txt")"

# 3. the What list is cut at the merge base with origin/main, spec commit excluded
meta "$TITLE"
drive "$W"
[ "$(cat "$T/out/what.txt")" = "- BH-1415: derive the PR title from ticket meta" ] \
  && ok || bad "3: What list is not this branch's own commits only: got '$(cat "$T/out/what.txt")'"
grep -q "spec(BH-1415)" "$T/out/what.txt" && bad "3: the spec commit is in the What list" || ok
grep -qE "^- (merge )?train:" "$T/out/what.txt" && bad "3: a main-train commit is in the What list" || ok
grep -q "BH-1313" "$T/out/what.txt" && bad "3: another ticket's commit is in the What list" || ok
[ -s "$T/build/pipeline.log" ] && bad "3: a clean What list logged the train warning: $(cat "$T/build/pipeline.log")" || ok

# 4. origin/main unresolvable: falls back to the local ref, still renders a What
( cd "$T/repo" && git update-ref -d refs/remotes/origin/main ) >/dev/null 2>&1
drive "$W"
grep -qx -- "- BH-1415: derive the PR title from ticket meta" "$T/out/what.txt" \
  && ok || bad "4: with origin/main gone the What list lost this branch's commit: '$(cat "$T/out/what.txt")' err=$(cat "$T/err.txt")"
( cd "$T/repo" && git update-ref refs/remotes/origin/main refs/heads/mainline ) >/dev/null 2>&1

# 4b. a branch whose OWN commit is train-shaped: the subject is KEPT (it is real
#     work), and the pipeline.log warning fires so the base resolution is audited
( cd "$T/repo" && git checkout -q ticket/bh-own ) >/dev/null 2>&1
drive "$W"
grep -qx -- "- train: #9 the branch's own commit" "$T/out/what.txt" \
  && ok || bad "4b: a real train-shaped commit of this branch was dropped: '$(cat "$T/out/what.txt")'"
grep -q "still carries a main-train subject" "$T/build/pipeline.log" \
  && ok || bad "4b: no pipeline.log line when a train subject survives the merge base: $(cat "$T/build/pipeline.log")"
( cd "$T/repo" && git checkout -q ticket/bh-1415 ) >/dev/null 2>&1

# 5. no meta and the only commit in the log is the spec commit: today's
#    behaviour, unchanged — HEAD's own subject, never an empty title
git init -q -b main "$T/only" >/dev/null 2>&1
( cd "$T/only" && git config user.email t@example.com && git config user.name t \
  && echo x > f.txt && git add -A \
  && git -c commit.gpgsign=false commit -qm "spec(BH-1415): the plan this build was executed from" ) >/dev/null 2>&1
nometa
( cd "$T/only" || exit 1
  env HARNESS="$T" BUILD="$T/build" OUT="$T/out" bash -c '
    set -uo pipefail; KEY=BH-1415
    . "$1"; printf "%s" "$PR_SUBJECT" > "$OUT/subject.txt"' bh "$TI" ) 2>"$T/err.txt"
[ "$(cat "$T/out/subject.txt")" = "spec(BH-1415): the plan this build was executed from" ] \
  && ok || bad "5: a log holding only the spec commit must still title the PR: got '$(cat "$T/out/subject.txt")' err=$(cat "$T/err.txt")"

# 6. the body's first line names the ticket, not the spec commit — and with
#    PR_SUBJECT unset it is byte-identical to the legacy path the three sibling
#    suites (pr-body-closes, evidence-block, hotfix-pr-label) rely on
meta "$TITLE"
drive "$W $TI $MN $EV"
[ "$(sed -n 1p "$T/out/body.txt")" = "Ticket BH-1415 — ${TITLE:0:80}" ] \
  && ok || bad "6: body line 1 is not the ticket line: '$(sed -n 1p "$T/out/body.txt")' err=$(cat "$T/err.txt")"
drive "$W $MN $EV"   # PR_SUBJECT never assigned: the legacy default
[ "$(sed -n 1p "$T/out/body.txt")" = "Ticket BH-1415 — spec(BH-1415): the plan this build was executed from" ] \
  && ok || bad "6: with PR_SUBJECT unset the body must render HEAD's subject as before: '$(sed -n 1p "$T/out/body.txt")'"

# 7. THE PRODUCTION ENTRY POINT: the real pr-create ladder block composes the
#    title it hands gh, and the body it writes to $BUILD/pr-body.md.
meta "$TITLE"
drive "$W $MN $EV $LA"
[ -s "$T/out/ladder-argv.txt" ] && ok || bad "7: the pr create ladder never called gh_pr_create_ladder: err=$(cat "$T/err.txt")"
[ "$(sed -n 4p "$T/out/ladder-argv.txt")" = "BH-1415: ${TITLE:0:80}" ] \
  && ok || bad "7: the title argument is not 'BH-1415: <ticket title>': '$(sed -n 4p "$T/out/ladder-argv.txt")'"
grep -q "spec(BH-1415)" "$T/out/ladder-argv.txt" && bad "7: the spec commit subject reached gh" || ok
awk '/^## What/{f=1;next} /^## /{exit} f' "$T/build/pr-body.md" | grep -q "^- BH-1415: derive the PR title from ticket meta" \
  && ok || bad "7: the PR body's What section lost this branch's commit: $(awk '/^## What/{f=1;next} /^## /{exit} f' "$T/build/pr-body.md")"
grep -qE "^- (merge )?train:|^- BH-1313:|^- spec\(" <<<"$(awk '/^## What/{f=1;next} /^## /{exit} f' "$T/build/pr-body.md")" \
  && bad "7: main's commits are in the PR body's What section" || ok

echo "run-build-pr-title: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
