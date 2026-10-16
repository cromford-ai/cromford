# Daily digest: a per-day cap on route reads (BH-6727, the sixth row source)

Doc: OPERATOR-SETUP

## Why

The ticket measured D1 rows read per hour at about 100M, with a jump to about
155M between 07:00Z and 13:00Z. Slice 1 (#6749) fixed the five named query
shapes. It did not find the source of the 07:00Z jump.

The jump starts at 07:00Z. That is `DAILY_DIGEST_SEND_HOUR_UTC` (default 7).
The `daily-digest` hub lane runs every 15 minutes (`*/15`).

`bin/daily-digest.sh` capped only failed SENDS (`attempts-<D>`, 3 a day). A
failed READ of `GET /api/metrics/daily-digest` exited with `read-failed` and
counted nothing. A failed render, a failed claim and a lost claim did the same.
So on a day when the route failed, the lane read the route again on every tick
from 07:00Z to 23:45Z: 68 ticks. Each tick goes through `_jobs_req`, which
retries a transport error once and a 503 "overloaded" once. One tick is 1 to
4 requests.

Before #6749, one digest read cost about 1,293,710 rows (the correlated
`EXISTS` in `worker/jobs/src/lib/daily-digest/core-sections.js`). A heavy read
makes D1 answer "overloaded", the read fails, and the next tick reads again.

## Calls/hour x rows/call

| | calls/hour | rows/call | rows/hour |
|---|---|---|---|
| Before #6749, bad day (ticket table: 27 calls in 2 h) | 13.5 | 1,293,710 | about 17.5M |
| After #6749, bad day, no cap | up to 16 (4 ticks x 4 requests) | about 900 (estimate) | up to about 14,400 (estimate) |
| After #6749 and this cap, bad day | up to 16, for 2 hours only | about 900 (estimate) | 0 after the 8th tick |
| Normal day | 1 read a day | about 900 (estimate) | about 900 a day (estimate) |

The "about 900" rows/call is an estimate, not a measure. The live measure
below found the `MIN(issue_created_at)` shape at 1,910 rows/call (60 calls,
2026-10-16 07:00-08:00Z). That shape also serves other routes, so the digest
read alone is not separated.

17.5M rows/hour is part of the 55M/hour jump, not all of it. The route also
runs its other section reads on each call. Those rows are not in the ticket's
top-5 table. This box has no `CLOUDFLARE_API_TOKEN`, so it cannot measure them.
This note does not claim the loop explains the whole jump. The live re-measure
below checks it.

## What changed

- `bin/daily-digest.sh`: a new counter `state/daily-digest/reads-<D>` (one
  integer, per box). The lane adds 1 to it immediately before the route read.
  Every tick that reads the route counts, whatever the result.
- At `reads-<D>` >= `DAILY_DIGEST_READ_MAX` the tick sends no request, writes
  no summary line, and exits 0. One warn `daily-digest-reads:<D>` a day
  (`alert_once`, stamp `alerted-reads-<D>`).
- The check is right after the dedupe block, after the send cap. A day that
  is already sent exits at the dedupe and never reads the counter.
- The 30-day name-date prune removes old `reads-<D>` files.
- `catalog/lanes.d/daily-digest.knobs.d/DAILY_DIGEST_READ_MAX.json`: knob
  `DAILY_DIGEST_READ_MAX` (int, default 8, 1..96, settable; its own fragment,
  BH-4987). 8 reads is 2 hours of ticks. Outside 1..96 is
  one warn note and the default.
- Suite: `tests/daily-digest-read-cap.bh-6727-test.sh` (R1-R8, M1).

Two hubs during a lease handover each keep their own counter, the same as
`attempts-<D>`. The worst case is 2 x `DAILY_DIGEST_READ_MAX` reads.

## Live measure after #6749 and #6767 (2026-10-16, before this cap deploys)

Run from the Mac at 19:50Z with an account token for the jobs account
(`d1AnalyticsAdaptiveGroups` by hour, `d1QueriesAdaptiveGroups` by shape,
database `harness-jobs`).

- Rows read per hour, 2026-10-15 19:00Z to 2026-10-16 19:00Z: 14.4M to 22.6M,
  most hours 17M to 21M. The ticket measured about 100M, with 155M from 07:00Z.
- 07:00Z to 09:00Z: 21.5M and 21.4M. No jump at the send hour on this day.
- `MIN(issue_created_at)`: 1,910 rows/call (was 1,293,710).
- Shapes over 5,000 rows/call, 2026-10-16 17:00-19:00Z: the `cost_rows`
  `SUM(CASE WHEN ts >= ...)` by project/stage, 129,155 rows/call (33 calls);
  the `job_artifacts` join, 8,293 rows/call (456 calls) and 12,072 rows/call
  (89 calls).
- Result: the five ticket shapes are fixed. The hourly total is still over
  the 15M target, and three shapes are over 5,000 rows/call. Those shapes are
  not the digest route, so this cap does not change them.

## Live re-measure (owed after the jobs worker deploy)

#6749's SQL and this cap reach production only when the jobs worker and the
hub deploy. Then, on the hub:

1. Run the `d1QueriesAdaptiveGroups` GraphQL query from the ticket body for a
   2-hour window that starts at least 3 hours after the deploy. Group by query
   and sort by `rowsRead`.
2. Record the total rows read per hour (target: under 15M) and the top shape's
   rows per call (target: under 5,000).
3. Record the Sentry CROMFORD-HARNESS-W event count for the 24 hours after the
   deploy (target: 0).
4. Post the numbers on #6727 with the window and the probe time.
