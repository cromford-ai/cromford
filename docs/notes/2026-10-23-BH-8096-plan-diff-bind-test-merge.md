# plan-diff-bind judges the PR head, not GitHub's test merge (BH-8096)

Doc: TESTING

## Why

The lint job ("Syntax + shellcheck + config integrity") checks out with no
`ref:`. On a `pull_request` run that is GitHub's synthetic test merge, a
2-parent commit `Merge <PR head sha> into <base sha>`. BH-7739 binds a batch's
one plan to its own member by reading the first-parent chain of
`<fork>..HEAD`. Under the test merge that chain is one commit, so the whole
draft read as "batch of 1 members", and every file of every other member was
charged to the one plan.

Evidence: draft #8101 (job 120159938599) and draft #8113 (job 120210066415).
Job 120210066415 logged
`HEAD is now at d2734cec7 Merge 1d0b16653a6f63830321eff0c6685c12d9e57e87 into 2e29460ef76d3afd7299f116aa374317cf580445`
and then `changed-not-planned bin/docker-pool-runner.sh .harness/specs/BH-7836/plan.md`.
The draft head itself passed.

## What changed

`bin/lib/plan-diff-bind.sh` has a new function `pdb_pr_head <repo> <sha>`.
`pdb_check` calls it after the head and base resolve, before the fork is
computed.

- The rule: `<sha>` has exactly 2 parents, and its subject is exactly
  `Merge <p2 full sha> into <p1 full sha>`. Then the check judges p2, the PR
  head. stderr: `plan-diff-bind: HEAD <sha12> is the PR test merge, judging
  the PR head <sha12>`.
- Any other commit is judged as before: `Merge branch 'main' into a`,
  abbreviated or swapped shas, a 1-parent commit with that subject, an octopus
  merge, a Mergify `Merge of #N` draft head.
- A failed `git log` returns the input commit (the old behavior).

After the unwrap a draft reads as a batch, and BH-7739's member binding
applies. An ordinary PR reads as its own branch. The rc contract and the stdout
finding format do not change.

The function name, signature, subject test and stderr wording are the same as
in open PR #8134 (BH-8109), so the two combine. The per-member multi-plan loop
of #8134 is not in this change: a batch with 2+ plans still skips with rc 0.

## Tests

`tests/plan-diff-bind-test-merge.bh-8096-test.sh`: P1-P4 build real Mergify
drafts and wrap them in a test merge (P1 failed on main with
`changed-not-planned bin/b.sh`). N1 proves an ordinary PR gives the same rc and
stdout under the test merge as on its head. N2-N6 prove the near-miss shapes
are not unwrapped.
