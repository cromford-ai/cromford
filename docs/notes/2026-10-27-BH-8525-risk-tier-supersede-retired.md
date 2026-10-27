# The lead lane no longer supersedes enqueue requests on a risk-tier head (BH-8525)

Doc: OPERATING

Slice C0 of #8525 (BH-8363.2). `bin/lead-review.sh` `review_one` had one skip (BH-5022): a request row with
`requested_by lead-review-enqueue:*` on a head with a standing risk-tier MERGE was posted `superseded`, with no
model call, and the log line `superseded <key>: signed off by risk-tier`. This slice removes that skip and puts
nothing in its place. Such a row is now reviewed like any other request row.

## Why the skip was dead

- Only `bin/lead-review-enqueue.sh` writes a `lead-review-enqueue:*` row.
- No cron fragment starts the enqueue since BH-7235. Its lane JSON is gone since #8503.
- Its other launcher, `lre_wake_launch` in `bin/lib/lead-reenqueue.sh`, has no caller outside the script.

So no new row of that kind appears in production. A hand run of the script can still write one. On a risk-tier
head, that row now costs one paid review. The paid-once ledger (BH-2202) and `LEAD_REVIEW_MAX_PER_PR_DAY` stay in
front of the call.

## What covers a risk-tier head now

Worklist gate 60 (`bin/lib/lead-gates.d/60-risk.sh`) holds a risk-tier head before the lead tick starts a review.
That is unchanged. `tests/lead-gates-risk-ports.bh-7236-test.sh` and `tests/lead-gates-risk.bh-5875-test.sh` pin it.

## Tests

`tests/lead-verdict-risk-tier.bh-5022-test.sh` C3 now runs `lead-review-enqueue:hub` in the C3b loop with the
three other requesters: each one is reviewed (`outcome done`, the agent ran). A new assert proves that
`logs/lead-review.log` has no `signed off by risk-tier` line. The two controls do not change.

## Why the script stays

12 suites still run `bin/lead-review-enqueue.sh tick`. #8496 and its children (#8524, #8526, #8527) remove those
cases. Open PRs #8489 (BH-8476) and #8135 (BH-8079) edit the script. Deleting it now makes those suites red.

## Next slice (C1 of #8525, Blocked-by #8496)

- Delete `bin/lead-review-enqueue.sh`, `bin/lead-review-enqueue.d/` and its `catalog/list-files.tsv` row.
- Delete the `pr`-mode lib `bin/lib/lead-reenqueue.sh` and `tests/lead-review-enqueue-frags.bh-8396-test.sh`.
- Remove the protected-path seed rows and their fixture lines.
- Remove the `requested_by lead-review-enqueue:*` branch of the replay rule in `bin/lead-review.sh`, and the
  request-row fixtures that use it.
- Fix the step 6 comments, the step 7 map rows and the tmp-sweep negative `lead-review-enqueue.ab12cd`.
- Add `tests/lead-enqueue-retired.bh-5870-test.sh`.

`bin/lib/autoenqueue.sh` is not the enqueue's lib. `state/lead-review-enqueue/` is the live state dir of the
worklist gates and stays.
