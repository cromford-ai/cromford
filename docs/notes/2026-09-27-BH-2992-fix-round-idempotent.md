# Fix-round finish and adopt retries are idempotent (BH-2997, BH-2992.3)

Doc: DB-COORDINATION-SPEC

## What changed

- **`bin/lib/fix-round-queue.sh`, `fix_round_finish`:** a 409 used to be rc 9
  whatever it said. The worker's 409 carries the row (`job`), so the client now
  reads `$JOBS_BODY` and answers rc 0 when the row proves this call's own
  outcome already landed: `status` is `done` or `adopted`, `claimed_by` is the
  calling box, and `result` is exactly the result sent (compared as a string
  through `jq --arg`). A replay prints nothing, as a 2xx finish does, and
  writes one `logs/jobs-client.log` line (`409 was a replay`) with
  `JOBS_ALERT=0`, so no ALERTS.log line. Every other 409, including `{}` or a
  body that is not JSON, stays rc 9.
- **`fix_round_adopt`:** a 409 whose row is `adopted` prints that row and is
  rc 0. A 409 on a `queued`, `claimed` or `done` row, or a body that is not a
  row, stays rc 9. The route records no adopter, so a replayed adopt cannot be
  told apart from another adopter winning. That is safe only because the
  resolver is the single adopter on the hub (flock-deduped per tick).
- **`worker/jobs/src/routes/fix-rounds.js`:** comment only. The finish comment
  said a box whose stale claim was re-offered "cannot overwrite" the new round.
  Claim always sets `claimed_by` to the requesting box, so the re-offer goes to
  the same box, and a late finish from that box's older session succeeds. The
  claim records the box, not an attempt id.
- **Test 8** of `worker/jobs/test/fix-rounds-routes.bh-2670.test.js` seeded
  `claimed_by: 'dead-box'` on a `box-a` row, a state no route produces. It now
  seeds `claimed_by: 'box-a'` and pins the real behavior: after the re-claim
  (attempt 2), a late same-box finish answers 200 and the row is `done`.

## Why

The claimer (#2826) and resolver (#2872) reach the queue only through this
client. A retried finish or adopt whose first answer was lost got a 409 and
read it as a refusal, so the resolver returned before it processed the
round's result.

## Tests

`tests/fix-round-queue-idempotent.bh-2992-test.sh` drives the real
`_jobs_req` through a curl shim with the worker's 409 shape.
