# A batch failure follows its patch, not only its sha (BH-8186)

Doc: MERGE-CONDUCTOR, MERGIFY

## What happened

- 13:30Z: #8128 failed its Mergify batch on `a69eedb1`.
- 14:06Z: Mergify dequeued #8127 with `dequeue_reason.code =
  BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS`, check `Pure-logic gate fixtures`,
  "Left the queue … at `3b036d004e90`".
- 15:43Z: the harness force-pushed #8127 to `653fca8a`. The author dates and
  the messages did not change. It was a rebase of the same patch.
- 16:13Z: the same for #8128 (`a69eedb1` -> `5d9112e4`).
- 19:02Z and 19:03Z: the conductor's READY arm added `merge-queue` and posted
  `@mergifyio queue` on both. They went into #8105's batch.

## The cause

Every failure mark of the conductor is keyed on the sha: `ejected`,
`dqwculprit`, `reejected`, `bejv`, and `bej_parse_dequeue`'s head binding.
The approval follows the patch: `rebind_patch_id` moves it to a rebased head
with the same patch-id. So the rebased sha was READY with no failure on it.

## The rule now

The approval and the failure both follow the patch, judged by the same two
rungs: a verbatim patch-id, then `mc_patch_same`'s clean-main-merge proof.

1. At an ejection on a Mergify repo, the settle arm reads the dequeue payload.
   A code in `MC_FAILED_BATCH_CODES` whose "Left the queue" sha is this head
   writes a `failed` line with the head's patch-id, the draft and the checks
   to `state/merge-conductor/failed-batch/<owner_repo>_<pr>`. A failed read
   writes `pending`, and the hold reads the payload again.
2. A READY head with a live record is judged before any enqueue: in the
   requeue arm before its re-entry gate, and before the READY arm.
   - A different patch: `cleared:new-patch`, and the head goes on.
   - The patch could not be compared: `WAIT_CI` for this tick only.
   - The same patch, and the solo re-run (`bs_batch`, BH-4550) passed:
     `cleared:bystander`, and the head goes on.
   - The same patch, and the solo re-run reproduced the failure:
     `BLOCKED_HUMAN prequeue-red: …`, which the resolver owns.
   - The same patch, no verdict: `WAIT_CI` with the failed-batch reason, for
     at most `MC_FAILED_BATCH_UNJUDGED_HOLD_S` (one day). Then
     `cleared:window`, once.
3. A requeue by the requeue arm clears the record as a bystander.

`PR_MANUALLY_DEQUEUED` and `CONFLICT_WITH_BASE_BRANCH` record nothing.

## Change from BH-5819

BH-5819 gave a bystander of a failed batch one requeue on the same head. For
a dequeue whose code counts, that requeue now waits for the solo re-run's
`clean` verdict or for the window. Mergify dequeues a PR with
`BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS` when it could not find the culprit, so
"not named" is not proof of a bystander.

## Operate

- Off, with no deploy: settings row `lane.merge-conductor.mc_failed_batch=0`.
- Log lines: `FAILED_BATCH_RECORDED`, `FAILED_BATCH_PENDING`,
  `FAILED_BATCH_HELD`, `FAILED_BATCH_CLEARED <why>`, `FAILED_BATCH_UNRECORDED`,
  `FAILED_BATCH_GC n=<count>`.
- Retention: record files older than `MC_FAILED_BATCH_KEEP_DAYS` (14) are
  deleted, at most once per `MC_FAILED_BATCH_GC_INTERVAL_MIN` minutes (60). A
  record file keeps its last `MC_FAILED_BATCH_KEEP_LINES` lines (20).
- Probe after deploy: `grep -E 'FAILED_BATCH_(RECORDED|HELD|CLEARED)'
  /root/harness/logs/merge-conductor.log` on the hub, against the Mergify
  dequeues of the same day.
