# review-prs reports a /tmp cap only after N consecutive capped ticks, with the top 5 /tmp users (BH-9035)

Doc: OPERATING

## What happened

Sentry CROMFORD-HARNESS-6 had a `review-prs-tmp-capped` event from project-3-2
(201MB free, threshold 2304MB). The event went out on the first capped tick
of an episode. A single capped tick is not a defect. The event also named
only the 3 largest /tmp entries, which was not enough to find the cause
without box access.

## What changed

1. **Streak gate.** `rp_tmp_capped_report` (`bin/lib/review-prs-tmp.sh`)
   first adds the tick to `state/review-prs-tmp-capped.streak`
   (`<count> <first_epoch>`, under the marker's lock, shared by every project
   on the box). Below `REVIEW_TMP_CAPPED_MIN_TICKS` (lane review-prs,
   default 3) it logs `/tmp capped at <k>; capped tick <n> of <min>, not
   reported` and does not claim the window. At the threshold the BH-6130,
   BH-6132 and BH-6133 rules decide as before.
2. **Reset.** `rp_tmp_episode_end` removes the streak with the marker, when
   a tick measures free /tmp at or above the threshold. With a marker it logs
   `cap episode ended`, as before. With only a streak (no report yet) it logs
   `/tmp recovered (...); capped-tick streak reset`. A tick capped by
   `REVIEW_BOX_MAX`, memory or a low `REVIEW_CONCURRENCY` neither adds to the
   streak nor resets it.
3. **Fail open.** If the streak file cannot be written, the lane logs
   `tmp streak not counted: <file> not writable` and the window rule decides.
4. **Top N.** The event `top` and the log line `top:` carry the
   `REVIEW_TMP_TOP_N` (lane review-prs, default 5) largest top-level /tmp
   entries, largest first.
5. **New extra fields.** `capped_ticks` (null when the streak was not
   counted) and `min_ticks`.

Not changed: the stale-dir cleanup is `bin/tmp-sweep.sh` (age knob
`MIN_AGE_MIN`, `--dry-run`). The 2304MB threshold is still
`REVIEW_TMP_MIN_MB + 3 x REVIEW_WORKER_TMP_MB`.

## Not done by this build

The ticket's first item, a `du` on project-3-2 to find what holds /tmp, is an
operator step. This build did not run it: it has no access to project-3-2. From the
next event on, `extra.top` names the 5 largest /tmp entries.

## Operator check

1. On a capped box, read `logs/pr-reviews.log` for `capped tick <n> of 3`.
2. When the event arrives, read `extra.top` to find what fills /tmp.
3. To get the old first-tick behaviour, set `REVIEW_TMP_CAPPED_MIN_TICKS` to 1
   (`bin/harness-ctl.sh set review-prs REVIEW_TMP_CAPPED_MIN_TICKS 1`, or the
   settings page).
