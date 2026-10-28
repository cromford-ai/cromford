# A merged build PR whose issue close fails is retried, and a merged slice stops holding siblings (BH-7731)

Doc: MERGE-CONDUCTOR, FLY-POOL

## Problem

On 2026-10-20 TK-1364 (#1936, `Closes #1364`) and TK-1741 (#2004) merged and
their issues stayed open. Two defects let that happen:

1. `mc_settle_merged` (`bin/lib/mc/settle.sh`) writes the PR url to
   `state/merge-sweep-done.txt` before it runs the issue close-out. When the
   close-out failed (an unreadable PR read, a refused PATCH), no
   `issue-close-owed` marker was written. `bin/merge-sweep.sh` then skipped the
   record for ever, because `sweep_seen` found the url in the done-file. The
   conductor's log line said that `bin/reconcile-prs.sh` retries the close.
   That script has no issue-close call.
2. The pool's sibling gate (`pool_after_open`, `bin/fly-pool.sh`) read a queued
   row for a blocker as "in flight". A multi-slice ticket stays open after a
   slice merges, and its next slice waits in the queue, so every sibling waited
   until the 360-min ceiling.

The close RULE did not change: `issue_close_guard` still closes only on a
closing keyword for `#n` with no open child, or on the last slice (BH-6308).
A title alone never closes an issue.

## What changed

1. `mc_settle_merged` writes `<record>/issue-close-owed` before the close-out
   and removes it when the close-out settles (closed, or a slice kept open).
   A failure leaves it. The log line names merge-sweep as the retry.
2. `bin/merge-sweep.sh` lets a done record through when it holds
   `issue-close-owed`. The PR reads MERGED and the BH-784 retry
   (`sweep_close_issue`) runs. A done record with no marker is still skipped
   with no read. The `issue-commented` marker in the same record keeps the
   comment to one.
3. `pool_key_slice_merged <key>` (`bin/fly-pool.sh`) answers rc 0 when a local
   build record for the key has `PR_CREATED <url>` on line 1 and that url is in
   `state/merge-sweep-done.txt`. `pool_after_open` then judges a queued (not
   claimed) blocker by its PR reads alone: no open PR means done.
4. `bin/merged-build-closeout.sh` is a one-time, re-runnable backfill for the
   issues already stranded. Dry run is the default; `--apply` closes only the
   `close` answers of the guard, with one `CLOSED` audit line per close in
   `logs/merged-build-closeout.log`. It is not a cron lane.

## Operator check

On the hub, run `bin/merged-build-closeout.sh --project project-6` (dry run).
TK-1364 and TK-1741 must say `close`, and the 11 slice tickets `keep`. Then run
it again with `--apply`.
