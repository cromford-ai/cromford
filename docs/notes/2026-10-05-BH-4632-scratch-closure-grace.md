# The scratch-closure lint graces branches cut before it landed (BH-4632)

Doc: tests/README.md

## What was wrong

The BH-4552 lint (`tests/scratch-closure-lint.bh-4552-test.sh`, see
`docs/notes/2026-10-05-BH-4552-scratch-install-closure.md`) goes red when a
diff raises a suite's hand-copy count. The corpus does not run on an ordinary
PR, so a PR cut before the lint landed (d2994580) passed its own checks, then
turned its Mergify batch draft red and ejected every other member. Batches
#4559, #4610, #4150 and #4423 were ejected that way between 07:38Z and 08:50Z
on 2026-10-05.

## What changed

The lint's helpers moved, unchanged, to `tests/lib/scratch-closure-lint.sh`,
and `lint()` now asks `bin/lib/scratch-closure-grace.sh` about each raised
suite. The suite is graced, and prints its findings prefixed `WARN ` after one
line `WARN scratch-closure grace: <suite> +<n> hand-copies (head <sha12> cut
before lint <sha12>; grace ends <ISO>)`, only when all of these hold:

- L, the oldest commit on the upstream (`RATCHET_BASE`/`TI_BASE`, `origin/main`
  or `main`) that added the lint's path, is found from git. Nothing is
  hardcoded; a shallow clone that cannot see L gets no grace.
- Every PR head that touches the suite forked from the upstream at a commit
  that does not contain L. Rebasing onto post-lint main, or merging it, ends
  the grace, so the debt is paid the next time the branch is touched. A batch
  where a post-lint member touches the same suite is red.
- Fewer than `scratch_closure_grace_days` days have passed since L's committer
  time. The settings row is `lib.scratch-closure-grace.scratch_closure_grace_days`
  (`catalog/lanes.d/_lib.scratch-closure-grace.json`, default 14, 0 = off,
  max 60). With no harness root, as on a CI runner, the env
  `SCRATCH_CLOSURE_GRACE_DAYS` and then the registry default answer, so the
  grace for L ends at 2026-10-19T03:32Z unless someone changes the knob there.
- The suite has no uncommitted or untracked change. The working tree belongs
  to no head, so a builder's own new hand-copy is never graced.

The heads are HEAD on an ordinary run. On a Mergify batch draft
(`GITHUB_HEAD_REF` = `mergify/merge-queue/*`) they are the member heads: the
second parents of the merges on the draft's first-parent chain down to the
base, unwrapping GitHub's test merge first. A draft with no member merges falls
back to HEAD, which is post-lint and therefore red.

What counts as a hand-copy did not change.
`tests/scratch-closure-lint-grace.bh-4632-test.sh` pins every rule above.
