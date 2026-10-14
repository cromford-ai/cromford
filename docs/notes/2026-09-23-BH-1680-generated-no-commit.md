# Builds stop committing the files the conductor regenerates on merge

Doc: MERGE-CONDUCTOR, RUN-BUILD-GRAPH

## What was wrong

A path a repo declares in its `## Generated files` table is rebuilt on merge:
`bin/lib/rebase-job.sh` step 6b runs `mc_regen_generated` when the conductor
rebases a branch, and `bin/batch-resolve.sh` regenerates over a train union. A
build that committed one of those files anyway bought nothing but a conflict on
a hunk no ticket was about.

## What it does now

`bin/run-build.sh` has a new block, `# >>> generated no-commit`, right after
the spec artifact commit and before the first push. It sources
`bin/lib/generated-table.sh` and calls `gen_nocommit_strip "$BASE" …`:

1. It reads the table at `$BASE` from the same three homes, with the same cell
   rules, as `mc_regen_table` and `regen_table` (`AGENT_ARCHITECTURE.md`,
   `docs/verification-map/README.md`, `docs/verification-map/index/tail.md`).
2. It takes the paths in `git diff merge-base(BASE, HEAD) HEAD` that a row
   matches, as a literal or a whole-path shell glob.
3. It resets each one to the merge-base (or removes it when the branch added
   it) and commits that once as `chore(<KEY>): drop declared generated files`.
4. Only after the committed tree matches the merge-base on those paths does it
   write them to `$BUILD/generated-not-committed.txt`. The PR body then gets
   one line: `Generated files not committed: <paths> — regenerated on merge by
   the conductor.` That line is built from the committed tree, so a path that
   came back into the diff is never claimed.

Nothing changes for a repo with no table, a diff that touches no declared path,
or a box without the lib. A diff that is ONLY declared files is left alone and
the skip is logged, because the ticket is about those files. A failed reset or
commit puts the paths back as HEAD has them and adds no line.

It runs before the gates, the review lenses and the head-bound approval, so all
of them see the stripped head. Doing it at the PR stage would move the head
after the APPROVE.

## The new column

The table has a third column, `committed`. A row marked `committed` is a render
the repo's own CI checks, so builds still commit it. In cromford that is
`rules/CLAUDE.md` (BH-1336, checked by `bin/render-rules.sh --check`). Unmarked
rows are strip-eligible. `mc_regen_table` and `regen_table` ignore cells past
the second, so the merge side reads the table exactly as before. Neither was
moved onto the new reader.

## What it does not do

A fix round after review that adds a declared file back is not stripped. That
would move the head after the approval. A PR that merges without any conductor
rebase or train keeps the declared file as main has it until the next
regenerate, and the target repo's own drift check in CI stays the arbiter.

Verified by `tests/generated-no-commit.bh-1680-test.sh`.
