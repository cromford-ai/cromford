# BH-1310: the checkpoint squash resets onto merge-base($BASE, HEAD), not onto $BASE

**What happened.** Two project-5 builds were REVIEW_BLOCKED tonight by the
test-tamper gate for deleting tests they never touched: TK-2937
(`TAMPER_COUNT: 433 (deleted_files=40 deleted_cases=392)` on a nightly-E2E
ticket) and TK-2979 (`TAMPER_COUNT: 196 (deleted_files=20 deleted_cases=176)`
on a two-line, one-file tidy). Every "deleted" file in the TK-2979 list had
actually been ADDED to `origin/main` between 22:04Z and 01:34Z by other PRs.
The agent deleted nothing. `bin/review-rescue.sh` re-scanned, confirmed "real
deletion" from its own three-dot diff, and retired both to the resolver.

**Cause.** `CKPT_SQUASH_WIP` (`bin/run-build.sh` and its twin
`bin/lib/rb/plan.sh`) collapses a checkpoint branch's wip commits into one
before the PR, by soft-resetting to `$BASE` and re-committing the same index.
`$BASE` is the box's LOCAL ref for main. The TK-2979 box adopted a checkpoint
branch cut from main as it stood at ~21:49Z, but had pulled main fresh at
01:47Z — project-5 merged 64 PRs in the preceding 26 hours, so `$BASE` was
now well ahead of the commit the branch actually forked from. Resetting
straight onto that fresh `$BASE` re-parents the squashed commit onto a tip
that carries every file main gained in between; the soft reset never touches
the TREE (so "same tree, tidy history" was true), but the squashed commit's
new PARENT has those files and its own tree does not, so every downstream
diff-shaped gate reads them as deletions. `bin/test-tamper-scan.sh` and
`bin/review-rescue.sh` both already diff with the three-dot form
(`git diff "$BASE"...HEAD`, which resolves `merge-base($BASE, HEAD)` on its
own) — they were not the bug. The squash corrupted the input they diff from:
once `HEAD`'s literal parent IS `$BASE`, `merge-base($BASE, HEAD)` can only
resolve back to `$BASE` itself, no matter how three-dot-safe the caller is.

**The fix.** `CKPT_SQUASH_WIP` now resolves `mb=$(git merge-base "$BASE"
HEAD)` once, and resets/counts/logs against `$mb` instead of `$BASE`
everywhere in the function — the branch's real fork point, which a fresh
`$BASE` cannot move. A `$BASE` the merge-base cannot resolve against (an
unrelated or missing ref) is never silently treated as the tip: the squash
returns non-zero and logs `CHECKPOINT squash FAILED — could not resolve
merge-base(...)`, leaving the wip commits in place rather than guessing —
same "never fatal to a build" contract the squash already had for its other
failure paths. Both copies of the function (the driver's live inline body
and the dark twin in `bin/lib/rb/plan.sh`, kept byte-identical pending the
module cutover) got the identical change. No change was needed in
`bin/test-tamper-scan.sh` or `bin/review-rescue.sh` — their three-dot diffs
are correct once the ancestry they read is.

**Verification.** `tests/run-build-checkpoint-test.sh` case 6f builds a
fixture where main gains a test-shaped file (`tests/new-on-main-test.sh`)
AFTER a checkpoint branch is cut, drives `CKPT_SQUASH_WIP`, and asserts the
squashed commit's parent equals the true merge-base (not the fresh `$BASE`
tip), the tree is unchanged, `git diff --diff-filter=D main...HEAD` is empty,
and a direct `bin/test-tamper-scan.sh` run over the same fixture reports
`TAMPER_COUNT: 0 (deleted_files=0 ...)`. Case 6g asserts the fail-loud path:
an unresolvable `$BASE` returns non-zero, leaves the branch untouched, and
names both refs in `pipeline.log`. Both cases fail red on the unfixed
function (confirmed: the squash parents onto the fresh tip and
`test-tamper-scan.sh` reports the file deleted) and pass green with the fix.

**Side effects, not fixed here.** The harness-pushed `ticket/TK-2979` and
`ticket/TK-2937` branches on `example-org/project-5` still carry the bad squash
commits from tonight; both tickets are HOLD and being rebuilt on the Mac lane
from fresh main, so those branches can be deleted once this lands (or left —
nothing reads them).

Doc: RUN-BUILD-GRAPH
