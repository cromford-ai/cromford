# Stacked children carry a rewritten parent: restack by patch-id, never rewrite a parent with children (BH-5234)

Doc: MERGE-CONDUCTOR

## What happened

- Child #5053 (`ticket/bh-4969`) was cut from parent commits `6da7eac3` + `be7d4731`
  on `ticket/bh-4968` (#5010).
- At 2026-10-07T12:19:19Z #5010 was force-pushed by the harness while #5053 sat
  on it: a pure rebase onto newer main, so the new commits `20a97214` + `e5ca74e0`
  had the same author date, subjects and patches.
- #5010 landed by a merge commit at 13:14:39Z and the harness moved #5053's base
  to `main` at 13:16:25Z. `mc_restack` was handed #5010's pre-merge head, which
  is not in #5053's history, answered rc 6, and nothing restacked the child. It
  kept the old copies, and a hand sync merge (`aee2823b`) took #5010's content
  from main over an add/add on every file #5010 added.

## What changed

1. **Fork point by patch-id.** New `bin/lib/stale-parent.sh`. In `mc_restack`'s
   rc-6 branch (`bin/lib/mc/rebase.sh`), `sp_fork_point` looks for the child's
   real fork point, and when one is proven, `sp_replay` cherry-picks only the
   child's own first-parent non-merge commits onto `origin/<newbase>`. Sync
   merges are dropped and counted. The log line is
   `restack: parent rewritten — fork point <sha8> by patch-id, N own commit(s) replayed, M sync merge(s) dropped`.
   No proof, an interleaved range or a changed own diff stays rc 6, logged with
   the reason. The callers (`mc_stack_follow`, `bin/pr-url-reconcile.sh`, the
   conductor's dead-base arm) are unchanged. The push is a `synchronize`, so CI
   runs, and the approval bound to the old head is re-read by the head-bound
   review.
2. **Never rewrite a parent that has open children.**
   - `hold_push` (`bin/lib/hold-push.sh`) refuses a REWRITE push (the lease is
     not an ancestor of what is pushed) to a branch that open PRs are based on:
     rc 5, one line `NOT rewriting <branch>: open stacked children #a #b …`.
     An unreadable child list refuses with rc 4. A fast-forward push and a
     `new` lease read nothing.
   - `mc_restack` is the one sanctioned rewriter of a parent. It reads the
     branch's open children before the push (unreadable: rc 3, still owed),
     pushes with `HOLD_PUSH_CHILDREN=follow`, and then writes a
     `state/stack-follow/<owner_repo>#<child>` record for each child, with the
     OLD head as the parent head and the branch as the base. The pr_worker
     drain restacks them on the ancestor path: the grandchild cascade.
   - The run-build pre-PR update (`bin/lib/rb/pr.sh`, `# >>> rebase verify`)
     MERGES `origin/$BASE` instead of rebasing when the branch is already on
     origin and has open children, or its children cannot be read. The log
     line is `pre-PR update by MERGE: <branch> has open stacked children (…)`.
3. **Wait for the parent to merge.** `STACK_WAIT_PARENT_MERGE` decides whether
   a stacked child waits. `bin/unblocked-children.sh` emits no STACKABLE line
   for it, and the run-build stacked-child block (`bin/lib/rb/gates.sh`) ends
   `BUILD_DEFERRED stack-wait: …` with exit 3 before any model spend. A rollout
   wave child is one whose issue body has `Rollout wave N of M:`. On a board
   project there is no issue, so only `all` defers.
4. **`stale-parent` in pipeline-health.** Per project with a hub clone, one
   list of open PRs on the default branch and one fetch of their heads
   (`refs/ph-stale/<n>`, capped). Then `sp_stale_commits` runs on each. A hit
   pages `staleparent:<project>:<pr>`, naming the commit pairs and the
   `git rebase --onto` fix. It is in `RETRACT_NS`, a failed read or fetch
   carries the project's standing keys, and it never pushes.

## The fork-point rule

`sp_fork_point <wt> <base-ref> <head>`:

1. `L` = `git rev-list --reverse --first-parent --no-merges <base-ref>..<head>`,
   at most `STALE_PARENT_SCAN_MAX` commits. Empty: rc 1.
2. `S` = the `git patch-id --stable` set of every non-merge commit on
   `<base-ref>` committed since the oldest commit in `L` (minus an hour of
   slack). A rewritten or landed copy is committed after the child was cut, so
   the window is complete. `S` is read from the base's own history, not from
   `base..head`, so a copy the child also reaches through a sync merge still
   counts. That is the case `git cherry` misses.
3. The stale prefix is the longest leading run of `L` whose patch-ids are in `S`.
4. If that is empty, the squash form: the longest prefix whose cumulative diff
   (`git diff first(L)^ c`) has a patch-id in `S`.
5. A commit in `S` after the prefix: rc 2 (interleaved, refused).
6. A prefix: its last sha, rc 0. Otherwise rc 1.

`sp_replay` then compares every replayed commit's patch-id with its
original's. Any difference is rc 7, which `mc_restack` maps to rc 6: nothing
is pushed whose own diff is not the reviewed one.

## Return codes

| function | rc | meaning |
|---|---|---|
| `hold_push` | 5 | new: a rewrite refused, the branch has open stacked children |
| `hold_push` | 4 | now also: a rewrite whose children could not be read |
| `mc_restack` | 6 | unchanged meaning: not restacked, the parent sha is not an ancestor and no fork point was proven |
| `mc_restack` | 3 | now also: the restacked branch's own children could not be read |

## Knobs (`catalog/lanes.d/_lib.stale-parent.json`, through `lib_env_apply stale-parent`)

| knob | default | meaning |
|---|---|---|
| `STACK_WAIT_PARENT_MERGE` | `rollouts` | `off`: never wait (pre-BH-5234). `rollouts`: a rollout wave child waits. `all`: every stacked child waits. Invalid: `rollouts`, plus one line in `logs/stale-parent.log` |
| `HOLD_PUSH_REWRITE_GUARD` | 1 | 0: a rewrite push no longer checks for open children |
| `STALE_PARENT_CHECK` | 1 | 0: the pipeline-health section is off |
| `STALE_PARENT_MAX_PRS` | 30 | open PRs fetched and judged per project per tick, with a page-cut alert past it |
| `STALE_PARENT_SCAN_MAX` | 20 | first-parent commits walked for a fork point or stale commits |

## What usually lies

- A `staleparent` page on a PR that took a clean main merge is still real.
  A merge does not change the patch-ids of the child's own first-parent
  commits, so the old parent copies are still there.
- A squash-landed parent is only caught by the cumulative check, and only when
  the squash carries exactly the leading commits' diff. A squash that folded in
  review fixes matches nothing. That is rc 6, or no page.
- A child commit cherry-picked to main on purpose (a hotfix) is reported. The
  line says "carries commits already on main", which is true and worth a look.
- A wip-checkpoint squash before the PR (`CKPT_SQUASH_WIP`) on a published
  branch with children is a rewrite, and `hold_push` refuses it (rc 5).

## Out of scope

`bin/lib/archie-fm.sh` has its own restack, with its own fork-point logic and
observe/on modes, and it is not reworked here. Its push now passes
`HOLD_PUSH_CHILDREN=follow`, because it already records the restacked branch's
children and their heads in its row and restacks them from that ledger on the
next tick (`tests/archie-fm-stack.bh-4784-test.sh` S1); without it the new
guard would refuse every Archie restack of a middle-of-chain branch.
