# A culprit head is never requeued; only a new head clears it (BH-5819)

Doc: MERGE-CONDUCTOR

## What happened

- 2026-10-08 04:55Z: #5221, #5281 and #5301 were dequeued for a real batch failure. At 07:01Z they
  were back in batch #5455 on the same heads.
- 06:28Z: the stale-dequeue arm (BH-3480) requeued them because lead verdicts re-landed by hand
  bound the same heads after the dequeue (07:16Z comment on #5430).
- #5462 (13:39Z): a human `@Mergifyio dequeue` with evidence, after a solo check failed, left
  only a plain `ejected` mark, and the BH-636 re-entry arm gave the head one free requeue as a flake.

## What changed

1. **Culprits are marked.** `mc_eject_culprit_mark` (bin/lib/mc/queue.sh), read in the re-entry
   arm before the strike count and in the stale-dequeue arm, writes `dqwculprit` + `reejected` when
   a human posted `@Mergifyio dequeue` after the head was committed (not the conductor's own CR
   dequeue), or when Mergify's draft held the PR alone and fewer than MC_BATCH_EJECT_SHARED_MIN PRs
   failed alone on that base (the verdict bej_reentry_gate cached a tick earlier, so its one-tick wait
   and its culprit comment are kept). The strike count then hands the head to the resolver as
   `queue-ejected-twice`. A clean answer is remembered per head (`culpritchecked`).
2. **A culprit head is never requeued.** `mc_ejected_hold` is true for a head with a `dqwculprit` or
   `reejected` mark. The re-entry arm holds it WAIT_CI (`EJECTED_HELD`); the stale-dequeue arm never
   requeues it on a verdict newer than the dequeue (`STALE_DEQUEUE_EJECTED`). Only a new head clears it.
3. **A bystander is not frozen.** A head Mergify dequeued with no culprit evidence keeps the BH-636 /
   BH-4428 requeue: freezing it would stall good PRs until somebody pushes.
4. **One knob.** `MC_EJECTED_REQUEUE`: `culprit` (default) or `never` (hold every ejected head).

## What usually lies

- The conductor posts as the shared PAT, so a human dequeue is told apart from the conductor's own CR
  dequeue by the `crdequeue` mark, not by the login.
- A culprit that dequeue-watch did not name and no human dequeued, ejected from a multi-PR draft, is
  still decided by bej_reentry_gate as before (BH-4428).
