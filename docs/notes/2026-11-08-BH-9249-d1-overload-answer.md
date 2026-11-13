# BH-9249: one 503 answer for a D1 overload on every harness-jobs route

Sentry CROMFORD-HARNESS-24: `D1 DB is overloaded. Too many resources consumed
within a 10 second window` left `fetch` as an unhandled Error after
`withD1Retry` gave up. Only some routes caught the give-up themselves.

What changed (slice C0):

- `worker/jobs/src/lib/d1-overload-answer.js` `withOverloadAnswer` wraps the
  worker's `fetch`, inside `withStmtStats`. Route-level guards still answer
  first.
- GET and HEAD answer `503 {error:"D1 overloaded", detail, retryable:true,
  d1_attempts, route}` with `retry-after` from settings row
  `d1_overload.retry_after_s` (whole number 1..60, default 2, read from the
  in-memory snapshot only).
- Every other method answers `503 {error:"D1 unavailable", retryable:false,
  written:"unknown", d1_attempts, route}` with no `retry-after` and without the
  word "overloaded". `bin/lib/jobs/req.sh` re-sends a 503 that says
  "overloaded" for any method, and a write can give up after an earlier
  statement committed (the BH-6805 read-back case), so a write is not re-sent.
- Each give-up upserts one `d1_overload_streaks` row (route key
  `<METHOD> /<up to 3 segments>`, ids as `:id`). Sentry gets one event per
  `HARNESS_D1_GIVEUP_REPORT_AFTER` (default 3) give-ups of a streak, tagged
  `d1_route` and `d1_op`.
- A non-overload error still throws and reaches Sentry.

Not done here (slice C1): the index, batch or cache for the statement that
overloads. The `d1_route` and `d1_op` tags on the next event name it.

Tests: `worker/jobs/test/d1-overload-answer.bh-9249.test.js`.
