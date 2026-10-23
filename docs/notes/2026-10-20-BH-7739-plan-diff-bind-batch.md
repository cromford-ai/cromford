# plan-diff-bind judges a batch's one plan against its own member (BH-7739)

Doc: TESTING

## Why

`bin/lib/plan-diff-bind.sh` (BH-7273) bound the one changed
`.harness/specs/<KEY>/plan.md` to the whole `fork..HEAD` diff. A Mergify batch
draft of one planned PR and one plan-less PR holds one plan, so the check
charged every file of the plan-less member to the other member's plan. Draft
#7733 (run 39447804069, job 118714427486) went red on
`changed-not-planned tests/suite-reach-check.bh-7669-test.sh`: that file came
from #7730, and the plan was BH-7087's. #7730 was the main-red hotfix, and it
lost about 1 hour in the queue.

## What changed

`pdb_check` now reads the commit shape of `fork..HEAD` after it selects the one
plan:

- The range is a batch when `git rev-list --first-parent --parents` lists 1 or
  more commits, each one is a merge of exactly 2 parents, and no second parent
  is an ancestor of the fork. The members are the second parents.
- Each member's diff is `git diff --name-only $(git merge-base <base> <m>) <m>`:
  the same file list the member's own PR lint judged.
- If exactly 1 member diff holds the plan, the four kinds run on that member's
  diff only. stderr: `plan-diff-bind: batch of <K> members, <plan> bound to
  member <sha12> only`.
- If 0 or 2+ member diffs hold it, the check skips with rc 0. stderr:
  `plan-diff-bind: skip (batch: <plan> in <N> of <K> members)`.
- Any other range (an ordinary PR, a PR that merged origin/main, a stack, an
  octopus merge) keeps the whole-diff check.

The plan text, the top-level entries and the case-missing reads stay at HEAD.
The rc contract and the stdout finding format do not change. The 0-plan and
2+-plan skips run first, as before.

## Tests

`tests/plan-diff-bind.bh-7739-test.sh` (M1-M9, M4b) builds the batch shapes
with real `git merge --no-ff` drafts. M1 is the ticket's case and failed on
main with `changed-not-planned bin/b.sh`.
