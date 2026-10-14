# Stacked-child restacks: knobs, parents merged outside the conductor, and delete order

Doc: MERGE-CONDUCTOR

Follow-ups from the BH-1670 review (#1694). This note corrects that note's
"Not covered" section: parents merged by merge-sweep and poll-commands are now
covered.

## 1. The two give-up limits are registry knobs

`_mc_stack_follow_retry` (`bin/lib/mc/rebase.sh`) had `3` tries and `21600` s
as literals. Both are now required knobs on the `merge-conductor` lane
(`catalog/lanes.d/merge-conductor.json`), read through `lane_knob`:

| Knob | Default | Min | Max |
|---|---|---|---|
| `MC_STACK_FOLLOW_TRIES` | 3 | 1 | 20 |
| `MC_STACK_FOLLOW_GIVEUP_S` | 21600 | 600 | 604800 |

A settings row `lane.merge-conductor.mc_stack_follow_tries` (or `…_giveup_s`)
changes them. If one does not resolve to a positive integer (no `lane_knob`
and no env, or a non-numeric value), the follow is dropped on that failure with
the usual STACK_FOLLOW alert. The alert text names the knob and the value it
got. It does not fall back to a hidden default and it does not retry silently.

## 2. A parent merged outside the conductor still restacks its children

merge-sweep and poll-commands merge with `gh_pr_merge_rest … 1`.
`_gpm_delete_branch` (`bin/lib/gh-pr-merge.sh`) retargets each open child to
the parent's base before it deletes the branch. When that PATCH answers 200, it
now also writes the conductor's owed-follow record through `_gpm_owe_restack`:
`$HARNESS/state/stack-follow/<owner_repo>#<child>`, in the same 7 fields that
`mc_stack_pending_put` writes, with the parent's pre-merge head from the pull
object it already holds. `pr_worker` drains that record through
`mc_stack_follow`, the same way it drains the ones `conductor_settle` leaves.
The child is already on the base, so nothing is PATCHed again. `mc_restack`'s
ancestry check decides what happens next:

- the branch still contains the parent head: `rebase --onto origin/<base>
  <parent head>` and one push
- it does not (someone already rebased it): rc 6, the record is cleared, no push

A refused PATCH records nothing. If the head sha does not read or the write
fails, that is one line in the merging lane's log. The delete decision and the
merge verdict do not change.

Not covered: merges done by hand in the GitHub UI. Records for repos the
conductor does not manage are never drained.

## 3. No branch delete before the children are moved

With `delete_branch_on_merge` off, GitHub closes the open PRs based on a
deleted ref. It does not retarget them. That is how #1664 and #1666 closed when
#1659's branch was deleted. Three paths deleted without listing children first:

- `bin/lib/gh-shim/pr-write.sh` `gshim_prw_delete_branch` (`pr merge|close
  --delete-branch` through the REST shim). It now lists the open PRs based on
  the ref. On a merge it PATCHes each one to the PR's own base and deletes only
  when every PATCH landed. On a close, any open child keeps the branch (the
  parent never merged). A list that did not read, is not an array, or is a full
  page of 100 keeps the branch.
- `bin/merge-sweep.sh` and `bin/poll-commands.sh` gave `--delete-branch` to the
  real `gh pr merge` in their no-REST-verdict fallback. The flag is gone. After
  gh exits 0 they call `_gpm_delete_branch`: merge-sweep once its state read
  says MERGED on a repo with no queue, poll-commands when the queue reader does
  not say queued. That reader cannot see GitHub's native queue (it answers
  `unknown`), so the deciding check is inside `_gpm_delete_branch` itself. It
  retargets, records and deletes nothing unless the pull object it reads says
  `merged: true`. An enqueue leaves the PR open, its children where they are
  and its branch in the queue. Without the lib the branch is kept.

`tests/branch-delete-order.bh-1715-test.sh` pins the order behaviourally, and
also as an inventory of every branch-delete verb under `bin/`. The allowlist
holds the lib's ref DELETE, the shim's delete and its two flag parsers (close, merge), and
batch-resolve's two train-branch deletes (no PR is ever based on a train
branch). An allowlist entry that matches nothing fails the suite.

Tests: `tests/mc-stack-knobs.bh-1715-test.sh`,
`tests/stack-follow-sweep-merge.bh-1715-test.sh`,
`tests/branch-delete-order.bh-1715-test.sh`.
