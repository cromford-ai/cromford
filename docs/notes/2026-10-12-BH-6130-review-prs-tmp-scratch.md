# review-prs owns its /tmp scratch and reports a /tmp cap once a day (BH-6130)

Doc: OPERATING

## What happened

The review-prs pool on box-project-6-1 ran at concurrency 1 because
/tmp was low. Sentry issue 7784795608 had 87 events and none of them said what
filled /tmp. The lane itself writes almost nothing to /tmp: its worker TMPDIR is
under `$HARNESS/tmp`. Its review agent is told the repo checkout "may be behind
the PR", so it makes its own checkout of the PR head under /tmp, and no lane
removed it. Only the 180-minute tmp-sweep did.

## What changed

1. **Owned scratch.** Each pool worker gets
   `<tmp>/review-prs-wk-<tick pid>/<worker id>`, and the review prompt tells the
   agent to put any checkout or temporary file there. The worker removes it on
   exit. The tick removes a SIGKILLed worker's dir when it collects it, and the
   root dir on exit. `<tmp>` is `REVIEW_POOL_TMP_PATH` (default /tmp).
2. **Stale removal at start.** Before `rpool_init` measures /tmp, the tick
   removes every `review-prs-wk-<pid>` whose pid is not a live `review-prs.sh`,
   then runs `git worktree prune` in the repo. Log line:
   `removed N stale scratch dir(s) under <tmp>`.
3. **The event payload.** `extra` now holds `free_mb`, `tmp_min_mb`,
   `worker_tmp_mb`, `threshold_mb` (floor + 3 workers), `tmp_path`, `fstype`
   and `top` (the three largest top-level /tmp entries, `du -sm`, bounded at
   20 s). The lane log gets one line with the same numbers.
4. **Once per box per window.** New knob `REVIEW_TMP_CAPPED_REPORT_S` (lane
   review-prs, default 86400, 0 = every capped tick). The marker
   `state/review-prs-tmp-capped.last` has no project in its name and is claimed
   under flock before the measure and the send.

The scratch, reap and report functions live in `bin/lib/review-prs-tmp.sh`.
The lane keeps the cap condition and the `sentry_report` call. `du` runs
without `-x`: on an overlay root a file reports another device than its
directory, and `du -x` then counts it as near 0.

## Operator check

After deploy, on a capped box, read `logs/pr-reviews.log` for the
`concurrency capped at … top:` line, or the newest event of the Sentry issue.
If the top entries are not `review-prs-wk-*` or agent dirs (`rv*`, `pr*`), the
space belongs to another lane, and that lane needs its own ticket.
