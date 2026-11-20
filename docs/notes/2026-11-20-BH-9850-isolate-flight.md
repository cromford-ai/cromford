# BH-9850: no pending Promise shared across requests in the jobs worker

Sentry CROMFORD-HARNESS-26: the harness-jobs worker reported "This promise was
created by a request that has since ended" 3 times. The stack ended in
`d1OverloadGuarded` (`worker/jobs/src/lib/http.js`).

## Cause

`d1OverloadGuarded` keeps no state. It awaits its `fn`, and that `fn` awaited a
promise that another request made. Three per-isolate caches kept a PENDING
Promise in module state and gave it to every later request:

- `ensureTable` (`createdTablesReady`) and `ensureColumns` (`addedColumnsReady`)
  in `worker/jobs/src/lib/core.js`;
- `settingsRows` (its in-flight map) in `worker/jobs/src/lib/settings-cache.js`.

`GET /api/flags/<ported>` calls `ensureTable(env, "harness_flags")` inside
`d1OverloadGuarded`, and every box polls it on every tick. In workerd a promise
belongs to the request that made it. When one of two requests ends first, the
runtime drops the continuation and reports the error. When the creator is
cancelled, its promise never settles, and every request that joined it hangs.

## Change

- New `worker/jobs/src/lib/isolate-flight.js`: `isolateFlight`, `detachFlight`,
  `flightKnobs`. A slot holds plain values only: `{ seq, running, startedAt,
  done }`. A request that finds a run in flight polls the slot on its own
  `setTimeout`, at most `ceil(wait_ms / poll_ms)` times, and takes the result.
  When the polls run out, it runs its own work. A poll count bounds the wait,
  so a frozen clock cannot make it endless.
- `ensureTable`, `ensureColumns` and `settingsRows` use it. The burst
  properties stay: a cold burst is one settings read (BH-9657) and one create
  per table (BH-658). A failed create or read is not kept.
- Two knob rows, seeded in
  `worker/jobs/schema.d/202611200707-bh-9850-isolate-flight-knobs.sql`:
  `d1_flight.wait_ms` (3000, whole number 0..7000, 0 = never join) and
  `d1_flight.poll_ms` (20, 5..500). They are read from the in-memory settings
  snapshot only, never by a D1 query. The seeds equal the code fallbacks.
- The D1 overload answer does not change: same 503 body, same retry knobs.

## Tests

- `worker/jobs/test/cross-request-promise.bh-9850.test.js` (F1-F9).
- `tests/isolate-flight.bh-9850-test.sh`.

## Not in this change

- `sentry` `sdk ||= import(...)` also shares a pending promise on a cold
  isolate. It is not on the reported stack. If the Sentry count stays above 0
  after deploy, it is the next site to convert.
- The ticket's "0 new Sentry events in 24 h" is live evidence after deploy.
