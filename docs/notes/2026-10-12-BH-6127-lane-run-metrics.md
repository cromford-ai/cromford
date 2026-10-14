# Lane-run metrics on Mission Control and the queue-wait alert (BH-6127, BH-6047 part 4 of 5)

Doc: VERIFICATION-MAP, PROJECT-LANES

## What changed

The lane-run queue (BH-6124) now has a console page and an alert.

- Mission Control has a new bottom-nav tab, **LANES** (`/lane-runs`). It shows
  three things for the last 24 h. Per lane: queued, claimed, done and died
  counts, the queue wait p50 and max, and the cost. Per machine: claimed, done
  and died counts and the last claim. And the hub's 1-minute load average with
  its age. A lane opens its runs, a run opens its detail (rc, PROF line,
  claimer, wait), and a claimer opens its machine's runs.
- `bin/lane-run-wait-alert.sh` is a new hub lane, `lane-run-wait-alert`, every
  minute. It alerts when the oldest queued run of a lane waits over the limit
  on 2 consecutive ticks. One warn alert per lane per breach, id
  `lane-run-wait:<lane>`. The alert resolves when the wait drops under the
  limit. The text is a fixed STE template. There is no LLM call.

## The settings row

`lane_run.wait_alert_min`, seeded `10`. An integer 1..1440. Any other value
(empty, `0`, `abc`, `1441`) uses the code default 10. A wait equal to the limit
is not over.

## The routes (harness-jobs, `worker/jobs/src/routes/lane-runs-metrics.js`)

- `GET /api/lane-runs?lane=&machine=&status=&limit=`: newest first. `limit`
  is 1..500, default 200. The answer has `truncated: true` when more rows
  exist. A bad parameter is a 400.
- `GET /api/lane-runs/<id>`: one run. `wait_s` is claimed_at - enqueued_at,
  or now - enqueued_at while queued. `run_s` is finished_at - claimed_at.
- `GET /api/lane-runs/metrics?hours=`: `hours` is 1..168, default 24. The
  window holds every run enqueued in it plus every live (queued or claimed)
  run. Cost is the sum of `cost_rows.cost_usd` with `box LIKE 'lane-run-%'`
  in the window, per `lane_id` (the rows BH-6126 writes). The `lane-fleet`
  pseudo-lane is `idle_cost_usd`. A failed cost read is
  `cost_available: false`. No hub load row is `hub: null`. Over a read cap
  (5000 wait-sample rows, 500 groups) the answer has `truncated: true`.
- `POST /api/lane-runs/wait-tick {box, load1}`: the alert decision. It counts
  consecutive over ticks per lane in table `lane_run_wait_alerts` and deletes
  the row of every lane that is not over, so one under tick resets the count.
  It answers `fire` (lanes with 2 or more over ticks and no ack) and `resolve`
  (deleted rows that reached 2 over ticks, acked or not). It stores `load1` in
  `lane_run_hub_load`.
- `POST /api/lane-runs/wait-ack {lane}`: stamps `alerted_at`. The script calls
  it after the alert is written. A lost ack re-fires on the next tick, and the
  alert id dedupes that send. If the lane drains before that tick, the lane is
  still in `resolve`, so the open alert id closes.

Schema: `worker/jobs/schema.d/0023-bh-6047-lane-run-metrics.sql` (two tables,
one settings seed, additive only).

## The lane

- Registry: `catalog/lanes.d/lane-run-wait-alert.json`. Cron:
  `cron/lanes/730-lane-run-wait-alert.cron`, behind `hub-lease.sh check`.
- Log: `logs/lane-run-wait-alert.log`, one line per run:
  `<ts> over=<n> fired=<n> acked=<n> resolved=<n> load1=<x|null>`, or
  `not-configured (<why>)`, or `worker-failed (<status>)`.
- No `JOBS_URL` or no `HARNESS_SECRET`: one log line, no request, no alert.
- The worker does not answer 2xx: one warn alert, id
  `lane-run-wait-alert:unreachable`, deduped by its id. No tick is counted.
- A lane name in an answer that is not `^[A-Za-z0-9._-]{1,64}$` is logged and
  skipped: no alert, no ack.
- Off: `bin/harness-ctl.sh off lane-run-wait-alert`.

## In prod today

Every lane is placed `hub` by default (BH-6124), so `lane_runs` is empty. The
page shows its empty state and the alert has nothing to fire on until an
operator sets a `lane_placement.<lane>=fly` row.
