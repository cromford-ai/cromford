# BH-7616: shed low-value polling lanes while the hub is over its load cap

Slice C0 of #7616 (the rest of #7397). Stacked on #7553 (BH-7509), which
writes the hub load verdict this slice reads.

## What it does

A lane manifest in `catalog/lanes.d/` can carry `"shed": true`. Only the
JSON boolean `true` counts: a string `"true"`, a number or `false` is no tag.

`lane_gate_or_exit` (`bin/lib/lane-gate.sh`) gets step 3d, "load shed". It
runs after the operator switches and the factory stop. A tagged lane skips the
tick when `hls_over` (`bin/lib/hub-load-shed.sh`, BH-7509) answers rc 0: the
file `state/hub-load/verdict` is fresh, well formed, `shed=1` and
`state=over`.

A shed tick takes the existing paused path:

- exit 0 (cron mails nothing, pipeline-health counts no failure);
- `state/lane-gate/<id>.paused` with the why;
- one throttled line in `logs/lane-gate.log`:
  `[lane-gate] <id> SKIPPED — load-shed p90=<p90> max=<max> (shed lane) (runs again when state/hub-load/verdict is not over; settings hub_load.shed=off stops all shedding)`;
- one `paused` liveness post with the why `load-shed p90=<p90> max=<max> (shed lane)`.

The gate checks the verdict file first. A box with no sampler (every box but
the hub, every Fly machine) pays one stat and never sources the reader. A
missing `bin/lib/hub-load-shed.sh` (a half-synced box) is read as NOT over and
logged once an hour as `load-shed: bin/lib/hub-load-shed.sh missing`.

No new knob. No new state file.

## The tagged lanes

| lane | cadence | why a skipped tick loses nothing |
|---|---|---|
| `issue-state-ledger` | */15 | pages GitHub issues `since=<watermark>`; the next tick resumes from the watermark |
| `ci-batch-ledger` | 11,41 | reads the runs of the last `CI_BATCH_LEDGER_DAYS` days against a skip-set; the next tick backfills |
| `orgo-state` | */5 | copies the Orgo computer list; the next tick overwrites it |

## Never tag

- a lane with a `factory_stop` tag (merge, launch, deploy lanes);
- a merge, review, alert, watchdog, reaper, heartbeat, liveness, probe, push
  or sample lane. `hub-load-sample` is the verdict writer, so it must never
  shed itself. `fleet-status-push` and `progress-push` feed the watchdog.

`tests/lane-load-shed.bh-7616-test.sh` G10 pins the tagged set and G11 scans
the real registry for the never-tag list.

## How to stop it

- All shedding, fleet-wide: set the settings row `hub_load.shed` to `off`
  (BH-7509). The sampler then writes `shed=0` and `hls_over` answers
  `shed-off`.
- One lane: delete its `"shed": true` line.

## Not in this slice (child slices of #7616)

- C1: cache GitHub reads per tick for the top `gh-calls` callers that
  `bin/hub-load-report.sh` names on the hub (other than the conductor and
  fly-pool).
- C2: the fleet rollout of the Fly pool tick after #7515 (BH-7505).
- C3: the after-measurement with `bin/hub-load-report.sh` over 1 h on the hub
  and over the launch-day hour (2026-10-18 16:00Z-17:00Z), with before and
  after numbers.
