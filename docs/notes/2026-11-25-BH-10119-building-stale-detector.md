# BH-10119 — `building_stale` uses its detector's filters

Item 5 of #10060 (scope 5 of #9558).

## What changed

- `bin/stale-build-reaper.sh` publishes its dead count after each complete tick.
  It writes one row to harness-jobs `ledgers(kind=building_stale, key=fleet)`
  through `job_ledger_put`.
- The kanban Pages function (`console-ui/functions/api/dash/kanban/pipeline.js`)
  reads that row in parallel with its other reads. While the row is valid, it
  replaces `building_stale` with the reaper's number.
- New knob `STALE_REAPER_COUNT_TTL_MIN` (lane `stale-build-reaper`, default 30,
  0 = do not publish). It sets the row's `valid_until`.

Before: the kanban showed the console worker's count. That count included builds
that were still queued, claimed, on a machine or beating their job row.

## The row

- `status`: the dead count, a decimal string. In observe mode it is every
  survivor. In act mode it is survivors minus reaped. A DEFERRED or REFUSED row
  still counts.
- `detail`: JSON `{stale, held, candidates, window_min, mode, at, valid_until}`.
  `at` is the tick clock (`--now` pins it). `valid_until` is `at` plus the TTL.

A refused tick (an unreadable feed or evidence source) exits before the publish
step, so it writes nothing. A failed PUT logs one line and does not change the
exit code.

## Fallback rules (reader)

`console-ui/functions/_lib/stale-overlay.js`. The console number stays, with
`building_stale_source: 'console'`, when:

| reason | cause |
|---|---|
| `unreadable` | no `HARNESS_SECRET`, a non-200/404 answer, a bad body, a thrown fetch |
| `no-row` | the ledger GET answered 404 |
| `bad-row` | `status` is not a non-negative integer, or `detail` has no parseable `valid_until` |
| `expired` | now is after `valid_until` |

A valid row sets `building_stale_source: 'reaper'`, `building_stale_at` (the
row's `updated_at`) and `building_stale_console` (the console's number, for the
audit). `valid_until` equal to now is still valid. The read is cached 60 s per
isolate (200 and 404 only).

The count stays fleet-wide; a project filter still marks it "(fleet)". The
Kanban screen did not change.

## Operate

- Turn the publish off: `bin/harness-ctl.sh set stale-build-reaper STALE_REAPER_COUNT_TTL_MIN 0`.
  The last row expires at its `valid_until` and the board falls back.
- Read the row: `bin/jobs-client.sh ledger-get building_stale fleet`.
