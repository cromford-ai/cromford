# review-prs reports a /tmp cap once per cap episode, with the review-prs dir count (BH-6133)

Doc: OPERATING

## What happened

Sentry issue 7784795113 had 63 `review-prs-tmp-capped` events from
box-small. BH-6130 cut the send to once per box per
`REVIEW_TMP_CAPPED_REPORT_S` (default 86400). That window also hid a second
cap: a cap that cleared and came back within 24 h sent no event. The event
also did not say how many review-prs dirs were in /tmp.

## What changed

1. **Cap episode.** A tick that is not capped by /tmp runs
   `rp_tmp_episode_end` (`bin/lib/review-prs-tmp.sh`). When it measures free
   /tmp at or above `TMP_MIN_MB + 3 x WORKER_TMP_MB`, it removes the marker
   `state/review-prs-tmp-capped.last` and logs
   `/tmp recovered (<free>MB free, threshold <thr>MB); cap episode ended`.
   The next capped tick sends at once. Inside one episode the window still
   sets the repeat (one reminder each `REVIEW_TMP_CAPPED_REPORT_S`).
2. **Measured space, not the cap reason.** A tick capped by
   `REVIEW_BOX_MAX`, memory or a low `REVIEW_CONCURRENCY` does not end the
   episode while /tmp is still under the threshold. An unreadable df keeps it.
3. **Dir count.** The event `extra` holds `review_prs_dirs`: the count of real
   `<tmp>/review-prs-*` dirs (symlinks are not counted). The event message
   ends in `, <n> review-prs dirs`. The lane log line does not change.

No new knob. Stale review-prs dirs older than tmp-sweep's `MIN_AGE_MIN` are
still removed at lane start by the sweep that `rpool_init` runs.

## Operator check

On a box that recovers, read `logs/pr-reviews.log` for `cap episode ended`.
The next cap sends a new event to the Sentry issue, with `review_prs_dirs`.
