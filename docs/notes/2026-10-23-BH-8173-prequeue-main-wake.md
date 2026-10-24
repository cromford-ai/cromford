# BH-8173: a finished pre-queue gate run wakes the READY PRs that wait on its main sha

Doc: MERGE-CONDUCTOR, EVENTS

## The defect

The conductor dispatches `prequeue-gate.yml` with `--ref main`. The run's
`check_run` and `check_suite` webhooks therefore carry the MAIN sha, and the
worker writes a `checks` wake row keyed on that sha.

Both wake consumers placed a checks sha in two steps: `pr-state.tsv`, then
`wck_sha_prs` (`GET commits/<sha>/pulls`). A main sha has no open PR, so:

- `bin/wake-loop.sh` logged `named no open PR (... miss=1 ...) — not launched`.
- `bin/merge-conductor-wake.sh` logged `skip no-open-pr`.

Every READY PR held `prequeue-pending` on that main then waited for the hourly
full tick. Hub evidence (2026-10-23): gate runs on main 682e769b were green by
about 11:20Z, and the PRs entered the queue only after the 12:0xZ tick.

## The rule

`bin/lib/wake-prequeue-keys.sh` runs BEFORE `wck_sha_prs`, in both consumers:

1. `wpk_pending` scans the conductor's own pre-queue cache
   (`state/merge-conductor/prequeue/`) for entries of that repo whose main is
   exactly the wake sha and whose first word is `pending`. No network read.
   A named-suites entry (`_<fp>` suffix), a sidecar or a `.tmp` file never
   matches.
2. If nothing is pending, the answer is rc 1 and no read is made. The
   consumer goes on to `wck_sha_prs` as before.
3. Otherwise ONE read lists the completed gate runs on that main
   (`runs?event=workflow_dispatch&head_sha=<main>&status=completed`). Each
   pending PR whose exact run title (`pq_run_title`) is in that list is woken.
4. If no pending PR's run has completed, nothing is woken (rc 3). Each run's
   own completion wakes its PR later.
5. If the read fails, every PR pending on that main is woken (rc 2,
   fail-open). The keyed conductor tick makes the final call.

The read comes from the same lookup budget (`WAKE_CONDUCTOR_SHA_LOOKUPS`,
`MC_WAKE_SHA_LOOKUPS`). It replaces a `commits/<sha>/pulls` read that always
missed, so the REST cost per drain does not go up.

The conductor is not changed. A keyed tick on a PR whose entry is `pending`
reads the finished run, settles the entry and enqueues on the same tick.

## Knobs

| Lane | Knob | Default | Meaning |
|---|---|---|---|
| wake-loop | `WAKE_CONDUCTOR_PREQUEUE_MAIN` | 1 | 0 = the path before BH-8173 |
| wake-loop | `WAKE_CONDUCTOR_PREQUEUE_PAGE` | 100 | per_page of the runs read, 1..100 |
| merge-conductor-wake | `MC_WAKE_PREQUEUE_MAIN` | 1 | 0 = the path before BH-8173 |
| merge-conductor-wake | `MC_WAKE_PREQUEUE_PAGE` | 100 | per_page of the runs read, 1..100 |

## Limits

- The pending source is the hub's own cache. A pending entry that only a
  lane-run machine wrote is not seen; that PR keeps today's path (its own
  `workflow_run` wake and the sweep).
- A completed run past the first page is a miss for that wake.

## Measure after the deploy

Run on the hub:

1. `grep 'prequeue main .* finished — woke' logs/wake-loop.log`
2. `grep 'reason=prequeue-main' logs/merge-conductor-wake-cron.log`
3. `bin/mc-ready-latency.sh --since <deploy> --target-s 300`

The acceptance target is gate completion to enqueue under 5 minutes, read
from step 3 with `measured>=5`.
