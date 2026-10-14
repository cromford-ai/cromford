# A slow human_verdict_mode read no longer fails a verdict read, and the land lane retries a 503 post (BH-5773)

Doc: MERGE-CONDUCTOR

## Why

`/api/verdicts` answered 503 `verdicts unavailable` often. The hub's
`logs/jobs-client.log` carried 475 lines of `human_verdict_mode could not be
read; standing is not answered (fail closed)` and 81 lines of
`D1_ERROR: D1 DB is overloaded`. On 2026-10-09 `lead-review-land` logged
`verdict row NOT posted ... (http 503)` 16 times. Each one delayed a lead
verdict by one land tick (15 min) or more.

The cause: `humanVerdictMode(env)` read the `settings` table on every request.
When D1 was busy that read threw, the mode was null, and GET `&head=` threw.
`d1Guarded` turned the throw into the 503.

## What changed

`worker/jobs/src/routes/verdicts.js`:

1. `humanVerdictMode` reads the mode again once, after 100 ms, when the first
   read fails.
2. When both reads fail, it uses the last good read of the same `env.DB` (one
   isolate) if that read is at most 60 s old. A failed read never replaces a
   good value. With no good read there is no cache, so the BH-3849 fail-closed
   rule still holds at cold start. The 60 s TTL and the 100 ms delay are code
   constants (`MODE_CACHE_TTL_MS`, `MODE_RETRY_DELAY_MS`): they bound the
   fallback for a failed `settings` read, so that table cannot hold them.
3. GET `&head=` with no mode: the worker checks for a `source='human'` row on
   that head. With none, it answers `standing` without the mode, because the
   mode only filters human rows. With one, it is still 503 (BH-3849).
4. A `source=human` POST with no mode is still 503. Its code does not change.

`bin/lead-review-land.sh`: when `bin/lead-verdict.sh post` fails with
`worker refused (http 503)`, the lane retries the post in the same tick after
2 s, 5 s and 10 s. Before each retry it reads the verdict rows again. A row
found means a 503 came after the INSERT: the lane takes the rc 4 arm (row
recorded, status not confirmed) and does not post a second row. A re-read that
fails or does not parse stops the retries; the next tick's step 1 decides. Only
a 503 is retried. A request that uses every retry makes the rest of the tick
post once, so one tick sleeps 17 s at most. The step-1 jq read moved into
`lrl_have` so the re-read uses the same rule.

Knob: `LEAD_REVIEW_LAND_POST_RETRIES` (`catalog/lanes.d/lead-review-land.json`),
0..3, default 3, 0 = off. A value outside 0..3 is logged and reads 3.

## The 60 s window

If an operator flips `human_verdict_mode` from shadow to enforce while every
fresh read fails, an isolate that holds a cached `shadow` can let a
lead-token human row stand, or accept an unverified human POST, for at most
60 s after its last good read. The ticket asks for this window. The
`HUMAN_VERDICT_ENFORCE=1` floor returns before any read, so the cache never
weakens the floor.

## Probes after the worker deploy

1. A GET `&head=&standing_only=1` for an open PR answers `200`.
2. The daily count of `human_verdict_mode could not be read; standing is not answered`
   in `logs/jobs-client.log` falls. A line is only possible on a head that
   carries a `source=human` row.
3. `logs/lead-review-land.log` shows `answered 503; retry` lines, and the daily
   count of `verdict row NOT posted` falls from 16.
4. `npx wrangler tail harness-jobs` shows `BH-5773` warn lines while D1 is busy.

Tests: `worker/jobs/test/verdicts-mode-cache.bh-5773.test.js` (C1-C5) and
`tests/lead-review-land-retry.bh-5773-test.sh` (R1-R7).
