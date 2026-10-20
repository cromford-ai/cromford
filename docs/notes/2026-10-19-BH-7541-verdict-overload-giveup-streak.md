# Verdict routes report a D1 overload give-up only on a streak (BH-7541)

Doc: worker/jobs/README.md

## What changed

Sentry issue CROMFORD-HARNESS-1G opened on single D1 overload give-ups of
`GET /api/verdict`. The route already answers 503 retryable (BH-6807), and
`bin/lib/jobs/req.sh` retries that answer, so one give-up is a transient.

- `overloadGiveUp` (`worker/jobs/src/routes/verdict.js`) calls `recordGiveUp`
  (`worker/jobs/src/lib/d1-giveup.js`) on every give-up. It sends a Sentry
  event only on every Nth give-up of a streak on that route.
- A streak is give-ups on one route where each comes within the window of the
  one before. A success writes nothing.
- `recordGiveUp` writes ONE upsert to `d1_overload_streaks` on the raw binding
  (one attempt, no retry). If that write fails, an in-isolate Map keeps the
  streak. It never throws.
- The warn line now ends `..., streak <n>: <message>`. The 503 body is
  unchanged.
- The event carries two new tags, `d1_giveups` (the streak) and `d1_route`,
  next to `lane`, `d1_attempts` and `d1_op` (`worker/jobs/src/lib/sentry.js`).

## Knobs

| var | default | meaning |
|---|---|---|
| `HARNESS_D1_GIVEUP_REPORT_AFTER` | 3 | send on give-up N, 2N, 3N ... of a streak |
| `HARNESS_D1_GIVEUP_WINDOW_S` | 900 | a gap longer than this starts the streak at 1 |

They are plain worker vars, not settings rows: they are read exactly when D1
is overloaded. Unset means the default. An invalid or < 1 value means the
default.

## Table

`d1_overload_streaks` (`worker/jobs/schema.d/202610200216-bh-7541-d1-overload-streaks.sql`):
one row per route name, PK `route`. It has a fixed size (2 routes today), so it
has no secondary index and no retention job.

## Limits

- The Sentry SDK keeps one client per isolate. Its dedupe integration drops an
  event equal to the isolate's previous event. So the event on the 6th
  give-up, right after the 3rd on the same isolate, is dropped there. The issue
  is already open from the 3rd.
- Not changed: `withD1Retry` already had exponential backoff with jitter
  (BH-6690, BH-6813). `prLedgerJob` has no writes to batch (2 point SELECTs).
  The jobs worker has no cron to offset.

## Tests

`worker/jobs/test/d1-overload-giveup.bh-7541.test.js` (G0-G8).
`worker/jobs/test/verdict-overload.bh-6807.test.js` V2 now asserts 0 Sentry
envelopes on a single give-up.
