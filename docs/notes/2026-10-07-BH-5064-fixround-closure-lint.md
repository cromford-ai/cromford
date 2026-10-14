# Blocked-resolver fix rounds run the scratch-closure lint before they push (BH-5064)

Doc: docs/verification-map/entries/BH-5064.md

## What was wrong

On 2026-10-06, four PRs (#4680, #4800, #4773, #4189) carried new suites that
hand-copied `bin/lib` files. Each one sank a Mergify batch. The ticket asked why
PR CI missed them, then asked for the lint in the builder gate, in fix rounds and
in PR CI.

This is what GitHub showed when the plan was written (read 2026-10-07 02:10Z-02:30Z,
times UTC). The build did not read it again.

| PR | head the batch took | that head's PR CI | #4884 (BH-4869, lint in PR CI) merged | pre-queue gate on that head | `merge-queue` label |
|---|---|---|---|---|---|
| #4189 | cc16d7ea (10-06 12:23Z) | 10-06 12:24Z | 10-06 18:51Z | run 37526085055, 20:23Z: red, `tests/lead-review-land-rings-conductor.bh-4057-test.sh:36` | added by hand 19:49:36Z; batch #5054 red 01:30-02:07Z |
| #4680 | 862c8e17 (10-06 09:49Z) | before 18:51Z | 10-06 18:51Z | run 37514898762, 18:54Z: red, `tests/pr-snapshot-wakes.bh-4661-test.sh:30` | added by hand 19:49:44Z; batch #4922 red 20:03-20:22Z |
| #4800, #4773 | — | before 18:51Z | — | — | merged 17:35Z, before #4884 |

What that means:

1. PR CI ran every check it had. Each head's checks ran before #4884 added the
   `scratch-closure` rules-pack row, and GitHub does not re-run a PR's checks
   when main moves. Mergify accepted the old green check on the head sha.
2. The builder's pre-push gate already runs the lint (`prepr_scan` in
   `bin/lib/prepr-gate.sh` runs `bin/rules-pack.sh`, which has carried the row
   since #4884). #4189 and #4680 were built before that.
3. PR CI already runs it (the `fast always-lints (BH-3860)` step, since #4884).
   So BH-4869 is the PR CI half of this ask.
4. The conductor's pre-queue gate caught both PRs. The `merge-queue` label was
   then added by hand, and a hand label never passes through `pq_gate`
   (`bin/lib/mc-prequeue.sh`). That is the hole that cost batches #4922 and
   #5054. This ticket does not close it. See "Not done here".
5. The real gap was blocked-resolver fix rounds. `br_fix_round` in
   `bin/blocked-resolver.sh` verified npm `typecheck` and `test:unit`/`test` only.
   cromford has no `package.json`, so a fix round here pushed after checking
   nothing but conflicts, author and guard silencing.

## What changed

- New lib `bin/lib/fixround-closure-lint.sh`: `frcl_scan <wt> <base> <out>` runs
  `bin/rules-pack.sh --tree . --base <base> --only scratch-closure` from the
  worktree. It is bounded at 3 × `RULES_PACK_BUDGET_S` and answers `clean`,
  `red`, `could-not-run`, `skipped` (no pack or no row: every product repo) or
  `off`.
- `br_fix_round` runs it twice:
  - **Before the agent.** Only when the merge of origin/main left no conflicted
    path. If it is red, the findings and the fix (`scratch_install_closure`) go
    into the brief.
  - **After the agent.** The result is part of `fix-verify.txt` as
    `== scratch-closure ==` / `CLOSURE_LINT_EXIT: <0|1|word>`.
    `CLOSURE_LINT_EXIT: 1` refuses the push the same way a red unit run does, and
    logs `the scratch-closure lint is red on the round's head … — not pushed`.
    `could-not-run`, `skipped` and `off` are recorded and refuse nothing.
- Knob `FIXROUND_CLOSURE_LINT` (libs fragment
  `catalog/lanes.d/_lib.fixround-closure-lint.json`, default 1). 0 turns it off,
  and rounds push on typecheck + unit alone, as before.

## Commands

    HARNESS_TEST_SANDBOX=1 bash tests/fixround-closure-lint.bh-5064-test.sh
    HARNESS_TEST_SANDBOX=1 bin/rules-pack.sh --only scratch-closure --runner local --base origin/main

On a box after a cromford fix round:
`/root/harness/state/blocked-resolver/cromford/<key>.fix-verify.txt` has a
`CLOSURE_LINT_EXIT:` line. A refused round shows up as
`grep 'scratch-closure lint is red' /root/harness/logs/blocked-resolver.log`.

## Not done here

- **A hand-applied `merge-queue` label still skips the pre-queue gate.** The
  options are: (a) the conductor dequeues a labelled PR whose cached pre-queue
  verdict for its current head is red; (b) `prequeue-gate.yml` posts a commit
  status that Mergify's `queue_conditions` require (a gating change, so it needs
  the BH-1000 probe); (c) leave it, since a hand label is a human override. That
  is the operator's call, so it is a separate ticket. The ticket's "7 days with no batch
  failure from this lint" proof depends on it, and this change alone does not
  cover it.
- `bin/lib/guard-silenced.sh` does not name `tests/lib/scratch-closure-lint.sh`,
  `catalog/rules-pack.tsv` or `bin/rules-pack.sh`, so a round that edits the lint
  itself is not caught as guard-silenced. The brief tells the agent not to edit
  them, and the conductor's re-review reads the diff.
