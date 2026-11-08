# BH-9229: a CHECKS_FAILED Mergify dequeue names its checks, and the resolver sends the park to the fix round

Doc: MERGE-CONDUCTOR, MERGIFY

## Cause

On 2026-11-08 #9189 left the Mergify queue twice: `BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS`
on `488caf3` and `CHECKS_FAILED` on `082b296`. Both comments state the code and
the failing checks in the payload JSON (`dequeue_reason.code`,
`dequeue_reason.checks`). The text has a `**Reason**` bold paragraph, not a
`## Reason` heading.

`ec_classify` (`bin/lib/mc-eject-cause.sh`) read the cause only from a
`## Reason` heading. It printed nothing, so `ec_cause` recorded
`unknown (no Mergify dequeue reason)` for both ejections. The PARKED row read
`queue-ejected-twice: 1 unknown (...) on 488caf37; 2 unknown (...) on 082b2964`.
No eject-runs file answered, so the resolver took `regen`. That rung cannot fix
a check that fails in the batch build.

## Fix

1. `mc_mergify_payload_dequeue` (`bin/lib/mc/queue.sh`, new, pure): reads the
   payload block of one Mergify body. It prints the dequeue code, then one
   check name per line. It answers only for `state == "dequeued"`.
2. `ec_classify` reads the payload first, after the Left-the-queue head check.
   A code that `MC_FAILED_BATCH_CODES` counts (row
   `lane.merge-conductor.mc_failed_batch_codes`, fallback
   `CHECKS_FAILED,BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS`) with at least one
   check gives `checks\t<a>, <b>`. Every other body takes the `## Reason` path
   as before. The record, the `EJECT_CAUSE` line and the PARKED row now say
   `checks (<names>)`.
3. `mc_dequeue_reason` prints `checks-failed:<a>,<b>` when the newest
   `mergify[bot]` comment's payload code is `CHECKS_FAILED` and names checks.
   The `github-review-approved` token is still answered first.
4. `mc_dequeue_surface` answers only `github-review-approved`. Its comment and
   fleet alert name a standing review, so any other token posts nothing and
   writes no `dequeue-surfaced` mark.
5. `bin/blocked-resolver.d/bh-9229-eject-checks.sh`: `brec_checks` reads the
   newest eject-cause record line for the row head. When its cause is `checks`
   with names, the `ejected twice: fix round first` block in `br_one` takes the
   fix round (from `mechanical` or `regen`, fix rounds not spent). `brec_brief`
   adds `THE MERGE QUEUE NAMED THESE FAILING CHECKS ON THIS HEAD: <names>` to
   the fix-round brief. `BR_OPT_OFF=bh-9229-eject-checks` turns this part off.

No backfill: a record that already says `unknown` stays `unknown`.

Not changed: `mc_dequeue_conflict` and `mc_mergify_names_review` still read
only a `## Reason` heading.

Test: `tests/mc-eject-checks.bh-9229-test.sh`, over the three real
`mergify[bot]` comments of #9189 in `tests/fixtures/bh-9229/`.
