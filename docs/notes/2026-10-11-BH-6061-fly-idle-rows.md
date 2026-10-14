# Fly idle stops get a cost row, and Mission Control shows the idle machines (BH-6061)

Doc: COST

The Fly idle reaper (`bin/fly-idle-reaper.sh`, the C2 part of BH-6061) stops
a started Fly machine that is idle above `fly.idle_stop_after_s`. This note
covers the worker side and the Mission Control panel that record and show
those stops.

## Worker tables (`worker/jobs/schema.d/0023-bh-6061-fly-idle.sql`)

- `fly_idle_stops`: one row per stop the reaper requested. The key is
  `stop_id` = `<machine_id>-<stop epoch>`. The row carries the app, machine,
  size, source, idle seconds, the threshold, `usd_per_hour` (the estimated
  cost saved per hour, or null when the size has no price) and `stopped_at`.
  `status` is always `requested`. It is a stop that flyctl accepted with rc 0,
  not a stop that was observed. The next pass shows whether the machine
  stopped.
- `fly_idle_machines`: the last pass's snapshot of started machines, with
  `idle_state` one of `busy`, `idle`, `over`, `stopping`, `unknown`,
  `nosignal`, `exempt`. An `unknown` idle time is null, never 0.
- `fly_idle_pass`: one row with the last pass time and its coverage
  (`apps_total`, `apps_failed`, `partial`).
- Four settings seed rows, `INSERT OR IGNORE`: `fly.idle_stop_after_s` = 900,
  `fly.idle_nosignal_alert_s` = 3600, `fly.idle_fail_alert_after` = 3,
  `fly.idle_max_stops_per_pass` = 10. A per-app override is
  `fly.idle_stop_after_s.<app>` and has no seed row.

## Routes (`worker/jobs/src/routes/fly-idle.js`)

All three use the worker's `HARNESS_SECRET` bearer.

- `POST /api/fly-idle/stops` `{rows:[...]}`: 1 to 50 rows. Every row is
  validated before anything is written. `INSERT OR IGNORE` on `stop_id`, so a
  replayed outbox post is a no-op. The answer is `{inserted, ignored}`.
- `PUT /api/fly-idle/machines` `{pass_at, apps_total, apps_failed, box, rows}`:
  0 to 500 rows. DELETE, INSERT and the `fly_idle_pass` upsert run in one
  `db.batch`. A bad row answers 400 and the old snapshot stays.
- `GET /api/fly-idle`: `{pass, machines, over_count, stops, stops_24h,
  unpriced_24h, saved_usd_per_hour_24h, window_since}`. `stops` holds the rows
  with `stopped_at` in the last 24 h, newest first, at most 200.
  `saved_usd_per_hour_24h` is the sum of the priced rows in the window.

## Mission Control

`/machines` has a FLY IDLE section (`console-ui/src/screens/FlyIdlePanel.js`,
pure shaping in `console-ui/src/lib/fly-idle.js`). The headline is
"N started · K over the idle limit · as of HH:MMZ", plus
"(partial: M apps not read)" when the pass did not read every app. Two sortable
tables follow: the started machines, and the stops in the last 24 h. Each
machine cell links to `https://fly.io/apps/<app>/machines/<id>` and each app
cell to `https://fly.io/apps/<app>`. A stop row with no price shows
`unpriced`, and the section line counts those rows apart from the $/h sum.

## Tests

- `worker/jobs/test/fly-idle.bh-6061.test.js` (W0-W5) drives the real router
  on the node:sqlite D1 shim. It posts the checked-in reaper fixture
  `worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json` and reads it back. The
  clock is the fixture time + 1 h (a `Date.now` stub).
- `console-ui/tests/fly-idle.bh-6061.test.js` (U1-U7) feeds the same fixture to
  the shaping functions and mounts the panel.
