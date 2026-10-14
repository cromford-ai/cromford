# A parent the conductor merges now restacks its stacked children

Doc: MERGE-CONDUCTOR

## What was wrong

project-5 #3180 was stacked on #3117. #3117 squash-merged. GitHub moved #3180's
base to `main`, but its branch still carried #3117's pre-squash commits, and
nothing pushed it. It had no CI run and a diff two tickets wide until someone
rebased it by hand. The stacked block in `pr_worker` only retargets a child and
kicks CI with a close/reopen. It never rebases.

## What it does now

When `conductor_settle` (`bin/lib/mc/settle.sh`) writes a parent `MERGED`, it
lists the parent branch's open children with `pulls?state=open&base=<branch>`
(`mc_stack_children`, a wrapper over `_gpm_open_children`). For each child,
`mc_stack_follow` (`bin/lib/mc/rebase.sh`):

1. reads the child fresh. A child that is not OPEN, or whose head lives in a
   fork, is left alone;
2. retargets it to the project base over REST (`mc_retarget_base`). If that is
   refused, nothing is pushed;
3. runs `mc_restack` with the parent's pre-merge head SHA as the upstream:
   `git rebase --onto origin/<base> <sha>`, then one `--force-with-lease` push.
   That push is a `synchronize` on a PR already based on `main`, so it is the CI
   trigger. There is no close/reopen kick on this path.

A replay that conflicts parks the child `BLOCKED_HUMAN` with reason
`conflict-unresolvable: stacked child of parent=#N (<url>) — …` and logs
`BLOCKED_AGENT`, so `bin/blocked-resolver.sh` picks it up through its existing
`conflict-unresolvable*` match.

`mc_restack` accepts a 40-hex SHA as `<old-base>`. It uses it bare, never
fetches it, and answers the new rc 6 when the SHA is not in the child's history
(the parent was rewritten after the child was cut). rc 6 is logged and the child
is left to the stacked block's existing retarget and kick.

## State

`$MC_H/state/stack-follow/<owner_repo>#<child>`, one file per child, written
(tmp + `mv`) BEFORE anything is sent. It is removed on every terminal outcome.
When the child's own worker holds its PR lock at settle time (`flock -n`, never a
wait), the file stays, and `pr_worker` drains it before the stacked block.
Observe mode records it and sends nothing. After 3 failed tries or 6 hours it is
dropped with one `mc_alert` naming the `git rebase --onto` to run by hand.
A settle that pushed a child writes `<file>.pushed` (tick id, new head). That
child's worker, if it runs later in the same tick, has a list row from before
the push, so it skips classification for that tick. A marker from an earlier
tick is just removed.

After a pushed follow, `pr_worker` returns for the tick instead of classifying.
Its CI state was read for the old head.

## Not covered

Parents merged outside the conductor (`bin/merge-sweep.sh`,
`bin/poll-commands.sh`) still only get their children retargeted by
`_gpm_delete_branch`. The stacked block's `MERGED` arm (retarget + kick) is
unchanged, and it is still the fallback for those.

Test: `tests/mc-stack-follow.bh-1670-test.sh`.
