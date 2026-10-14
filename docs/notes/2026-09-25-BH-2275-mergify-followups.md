# Mergify refuses a PR with a standing change request, and an unreadable probe holds

Doc: MERGIFY, MERGE-CONDUCTOR

## What was wrong (from the #2273 review)

- `.mergify.yml` queued on the label alone. A PR that got a lead CHANGES_REQUESTED after it was
  labelled could still be merged by the queue.
- A `.mergify.yml` probe that failed (5xx, rate limit, network error) read as "no queue". The
  conductor and the console Merge button then merged directly around the queue.

## What changed

- Every queue rule, in `config/mergify/template.yml` and the live `.mergify.yml`, carries
  `#changes-requested-reviews-by=0` in both `queue_conditions` and `merge_conditions`.
- `mc_cr_dequeue` removes our label and posts one `@mergifyio dequeue` per (PR, head, review). It
  runs in two places:
  - the conductor's QUEUED pass, when a lead/human CR stands on a queued PR (the row goes back
    to READY);
  - the READY arm's block-gate refusal, when a held PR still carries our label.
- `mc_queue_mergify_enabled` answers rc 2 on an unreadable file. `mc_queue_provider` then answers
  `unknown`, which is never cached. The four callers handle it this way:
  - the conductor holds the repo's tick and raises one alert per repo per day;
  - `mc_enqueue` refuses;
  - the console Merge button acks a retryable `merge failed`;
  - the stand-down lanes treat it as a queue.
- Cleanups: the `mc_enqueue_mergify` rc-3 comment now describes the hold, and the held alert says
  when the label could not be written.
