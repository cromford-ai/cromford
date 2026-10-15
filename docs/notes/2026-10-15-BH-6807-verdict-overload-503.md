# The verdict routes answer 503 when the D1 retry gives up (BH-6807)

Doc: VERIFICATION-MAP

## The gap

BH-6690 wraps every D1 call in the jobs worker with a retry: 3 attempts on
"D1 DB is overloaded", then the same error is rethrown. In `GET /api/verdict`
and `GET /api/verdict/history` (the 2 callers of `prLedgerJob`), nothing caught
that rethrow. It left the worker as a 500 with no body. `bin/lib/jobs/req.sh`
(BH-5781) retries only a 503 whose body says "overloaded", so the hub client
did not retry it.

## What changed

- `worker/jobs/src/routes/verdict.js`: `overloadGiveUp` wraps both route
  bodies. On an error that `isD1Overloaded` accepts, the route writes one
  `console.warn` line, sends one Sentry event through `captureException` (the
  `d1_attempts` tag stays), and answers
  `503 {error, retryable:true, d1_attempts}`. Every other error rethrows
  unchanged. A ledger miss is still a 404.
- `worker/jobs/test/verdict-overload.bh-6807.test.js` drives the real
  `worker.fetch` for each case.

## Not covered here

Other routes still let a give-up rethrow as a 500. A worker-wide handler in
`worker/jobs/src/index.js` is a possible follow-up.
