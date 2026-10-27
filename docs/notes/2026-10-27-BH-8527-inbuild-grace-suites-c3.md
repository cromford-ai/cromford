# The gate-70 suites lose their enqueue cases; ten live cases move to a worklist suite (BH-8527)

Doc: TESTING

Slice C3 of #8496 (BH-8496.3), the last numbered slice of #8496. Since BH-7235 no cron lane or wake starts
`bin/lead-review-enqueue.sh`, and since BH-8363 it has no lane row. Its in-build grace runs in
`bin/lead-review.sh tick` as the worklist gate `bin/lib/lead-gates.d/70-inbuild-grace.sh`. This slice cleans the
2 suites that still drove the grace through the enqueue `tick`. No file under `bin/`, `worker/`, `cron/` or
`catalog/` changes.

## What left which suite

- `tests/inbuild-grace-outside-push.bh-5740-test.sh`: deleted. Every case drove the enqueue `tick`.
- `tests/medium-tier-inbuild-review.bh-5023-test.sh`: the G block (G1-G8), the 3 enqueue checks of C2, the
  `enqueue` helper, `ELOG`, `esumm` and `bin/lead-review-enqueue.sh` in the hub closure went. The box, land and
  hook cases (one, C1-C4, L-noapprove, L-rebound, the L-enqueue row check, hook, secrets) keep their assertions.

## Where each case went

`.harness/specs/BH-8527/twin-map.md` has one row per case id of the 2 suites: TWIN (the worklist suite and case
that pins the same outcome), ENQUEUE-OWN (output only the enqueue wrote), PORT or KEPT.

The new suite `tests/lead-gates-inbuild-ports.bh-8527-test.sh` holds the ports. It drives
`bin/lead-review.sh tick` whole over the worklist fixture, with a test-local curl in front of it that answers
`GET /api/verdict?` with 404 or, from a counted read on, 500:

- IG1, IG3, IG4, IG6, IG6b, IG9 (bh-5740 G1, G3, G4, G6, G6b, G9): no live build job on the head; one job and
  one `inbuild-grace skipped` line that says why.
- IG5, IG5b, IG7 (G5, G5b, G7): a provisional running build, a `queued_for_retry` build, a failed job read; held.
- IG8 (bh-5740 G8, bh-5023 G8): grace 0 and a future-dated marker; a job, no skipped line, no awaiting line.
- IH3 (bh-5023 G3): a high head is never held. IR5, IR5c (bh-5023 G5): a 60 s grace row overrides the 3600 s
  default; the control is held.
- IGS: no secret in the logs. M1 and M2 mutate the scratch gate and flip IG3 and IG5b.

## What is left

Slices C1 (gate 50) and C2 (gate 60) of #8496 take the other suites that still run the enqueue `tick`.
