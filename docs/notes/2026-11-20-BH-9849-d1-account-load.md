# BH-9849: retry and answer 503 on the D1 account-load rejection

Doc: DB-COORDINATION-SPEC

## Cause

D1 rejected `GET /api/routing/<project>` with
"D1_ERROR: Your account is generating too much load on D1 DBs" (Sentry issue
CROMFORD-HARNESS-29, 9 events in 24 h). `isD1Overloaded` in
`worker/jobs/src/lib/d1-retry.js` matched only "D1 DB is overloaded". So
`withD1Retry` threw after one call, `withOverloadAnswer` rethrew, and
`worker.fetch` gave an unhandled 500.

## Change

`isD1Overloaded` now also matches "Your account is generating too much load on
D1 DBs" (case-sensitive substring, like the old match). This message gets the
same treatment as the old one:

- the retry with backoff and jitter (settings rows `d1_retry.attempts`,
  `d1_retry.base_ms`);
- on give-up, the 503 answer from `withOverloadAnswer`: GET/HEAD get
  `retry-after` (row `d1_overload.retry_after_s`) and `retryable: true`, a
  write gets `D1 unavailable`, `retryable: false`;
- the Sentry streak rule (one event per Nth give-up).

D1 sends this rejection before the query runs, so a retry never writes twice.
No new knob, table or index. The route's one query uses the `routing` primary
key.

Test: `worker/jobs/test/d1-account-load.bh-9849.test.js`.
