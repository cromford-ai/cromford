# BH-9406 (slice C0): the pre-PR rebase fails closed

Requested by Albin, approved by the operator 2026-11-10. Origin: TK-3738, a PR opened
DIRTY on outdated code.

## What changed

`bin/lib/rb/pr.sh`, inside `# >>> pre-pr rebase`:

1. New block `# >>> rebase fetch (BH-9406)`. The fetch of `origin/$BASE` was
   `|| true`, so a failed fetch read as "main did not move". It now runs up to
   `rebase_verify.fetch_attempts` times (default 3), `rebase_verify.fetch_sleep_s`
   apart (default 10). If no attempt lands, the build ends
   `BUILD_DEFERRED rebase-fetch: …` (exit 3) with no PR. `PUSH_BRANCH
   rebase-fetch` runs first, so the branch is on origin.
2. `# >>> rebase verify`: the typecheck body is now the function
   `rebase_typecheck`, with the same log lines and classification. The conflict
   arm records `RB_CONFLICT_PATHS`.
3. New block `# >>> rebase verify gate (BH-9406)`. A `REBASE_CONFLICT` or a
   `REBASE_VERIFY_FAILED` gets `rebase_verify.fix_rounds` fix rounds (default 1,
   `rebase_verify.fix_timeout_s` each, default 1800). A round passes only when no
   merge or rebase is in progress, no path is unmerged, the tree is clean, HEAD
   moved, `origin/$BASE` is in HEAD, a merge-update branch still contains its
   pre-update head, and the typecheck is green (INCONCLUSIVE passes with its
   note). If no round passes, the worktree is reset, nothing is pushed, and the
   build ends `REVIEW_BLOCKED rebase-verify: …` (exit 6) with
   `rebase-verify-block.txt`, 1 ALERTS line and 1 `escalate_block` beat.

Knobs: `worker/jobs/schema.d/202611110257-bh-9406-rebase-verify-knobs.sql`.
`rebase_verify.mode=note` (or `rebase_verify.mode.<project>=note`) is the
rollback to the old behaviour.

## Not in this slice

- Item 3: `ppr_reap_landed` rebases before it opens a PR (child slice C1; the
  pool rebase job is PR-keyed today).
- Items 4 to 7: the stale-build reaper lane, the PR open from a dead build's
  branch, and the spec-commit adopt (child slice C2).

## Tests

`tests/rebase-verify.bh-9406-test.sh` runs the whole `# >>> pre-pr rebase` block
against real git in scratch repos, with fake tsc, fix model and settings.
