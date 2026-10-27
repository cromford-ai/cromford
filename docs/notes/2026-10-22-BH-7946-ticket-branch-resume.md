# A pool build resumes its own ticket branch, and the watch does not hold it (BH-7946)

Doc: CHECKPOINTS

## What changed

A pool build cuts `ticket/<key>` when the name is free on origin. That check
runs once, at the cut. On 2026-10-21 a Mac session created `ticket/bh-7519`
41 minutes after the pool cut it. The finished build pushed with lease `new`,
origin refused it, and the stranded-ticket watch held the ticket for a human
(PR #7852). TK-1556 is the same failure on project-6.

1. `bin/lib/rb/pr.sh` has a new block, `# >>> ticket branch resume (BH-7946)`,
   before `# >>> pre-pr rebase`. It runs only when the lease would be `new`
   (no `refs/remotes/origin/<branch>`). It calls `tbr_classify` in the new lib
   `bin/lib/ticket-branch-resume.sh` and writes one pipeline.log line,
   `BRANCH-CHECK <verdict> <branch> remote=<sha> <detail>`.
2. On `own`, `tbr_resume` keeps this build's head at
   `refs/harness/superseded/<KEY>` (local only), checks the branch out at the
   remote head, and sets the lease to that sha. `SQUASH_OK` becomes 0. The
   pre-PR update then MERGES `origin/<base>` (never a rebase of a published
   branch). The existing typecheck and pre-push gate verify it. The push is a
   fast-forward through `hold_push`, and the PR opens. The PR body gets a
   `## Resumed from an existing branch` section. The approval of the set-aside
   head does not carry: the head-bound gate re-reviews.
3. On `ancestor`, the remote head is the lease and the update is a merge.
4. Before the push, a published branch whose HEAD does not contain the remote
   head is not pushed: `BUILD_DEFERRED … not-fast-forward`, exit 3.
5. The rejected RESULT line gains a suffix only when a check ran:
   `BUILD_DEFERRED push of <branch> rejected at <sha> branch-check=<verdict> remote=<sha>[ <detail>]`.
   The reap (`bin/lib/pool-push-rejected.sh`) and `bin/fly-pool.sh` read the
   prefix only, so they do the same as before.
6. `bin/orphan-reconcile.sh` `stranded_reoffer`: when the last result is a
   pool push-rejected terminal and the terminal reason (the pool_terminal row,
   else `state/pool/<p>/<KEY>.terminal`) does not say `branch-check=foreign`,
   the watch does not hold the ticket. It writes one ALERTS line per key per
   `STRANDED_REOFFER_WINDOW_H` (marker `state/stranded-push-rejected/<p>/<KEY>.alerted`)
   and skips the key as `push-rejected-own`. A foreign or unreadable reason
   keeps the hold, and the hold text now names the branch, its head, the first
   foreign commit and a one-line recovery step.

## The verdicts (`tbr_classify`, first match wins)

| Verdict | When | Effect |
|---|---|---|
| `tracked` | `refs/remotes/origin/<branch>` is set | no read; as before |
| `unreadable` | ls-remote, dirty tree, fetch, PR read, or no merge-base after one unshallow | refused as before, suffix names it |
| `absent` | the name is not on origin | as before |
| `open-pr` | an open PR has that head (REST pulls read) | refused as before |
| `ancestor` | the remote head is in HEAD | lease = remote head, fast-forward |
| `ancestor-of-base` | nothing on the branch past the base | as before |
| `own` | every non-merge commit past the base names the key or touches `.harness/specs/<KEY>/` | resume, merge base, fast-forward |
| `foreign` | any other commit | refused, suffix `first=<sha> by <author>` |

A commit names the key when its message has the key as a whole word, any case:
`BH-7946` matches, `BH-79460` and the child key `BH-7946.2` do not. The author
is never read for this.

## Recovery

- Not held (own branch): comment RETRY on the ticket. The next pool build
  resumes the branch from its head.
- Held (foreign commits): if the branch is this ticket's work, open a PR from
  it. Otherwise move that work to another branch and comment RESUME.

The lib never sends anything to origin, never forces and never deletes a ref.
Tests: `tests/ticket-branch-resume.bh-7946-test.sh`,
`tests/stranded-watch-push-rejected.bh-7946-test.sh`.
