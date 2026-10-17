# The Fly idle reaper reads work, probes, and destroys (BH-6877)

Doc: COST, OPERATOR-SETUP

## What changed

- `bin/fly-idle-reaper.sh` decides "used" from work, not from Fly events.
  Pool and builder idle counts from the last work time (a witness the reaper
  saw, kept in `state/fly-idle-reaper/work/`) or the newest `start`/`launch`
  event. `update` and `exec` events are not work.
- New source `lane-run`: `GET /api/lane-fleet/machines` (busy, in_flight,
  idle_s). The `lane_fleet.warm_floor` lowest-idle machines are kept.
- Before a pool, builder or lane-run stop, a `ps` probe through
  `flyctl machine exec` (`catalog/fly-work-procs.json`). A work process is busy.
- An app with no registry entry gets `metrics` (Fly Prometheus CPU and net,
  `bin/lib/fly-metrics.sh`). `project-12-*` is exempt (customer bots); four
  retired or lab project-12 apps have exact `metrics` entries.
- A pool, builder or lane-run machine stopped more than
  `fly.destroy_after_stopped_s` (7 days) is destroyed, one row each in
  `fly_idle_destroys`. `fly_idle_stops` and `fly_idle_destroys` keep 400 days,
  then roll into `fly_idle_daily`. The row's $/h is the compute rate a
  restart would cost, not a saving. A machine with a mounted volume, or the
  recorded builder of a `state/fly/<p>.json`, is never destroyed.
- `fly-no-claim-<digest12>`: one alert per lane-run image digest with a
  machine that made no claim in 600 s. Alert only.
- Quartermaster prints `fly-unsettled` findings and acts through
  `bin/fly-idle-reaper.sh act probe|stop|destroy|keep`.

## Operator setup

- The metrics signal needs the org slug: `FLY_ORG`, or the `Organization.Slug`
  of the apps list. With neither, an unregistered app stays `nosignal`.
- The destroy step ships ON (`fly.destroy_enabled=1`). Set it to `0` to turn it
  off. A `fly.destroy_after_stopped_s` under 86400 is refused for the pass.
- A new work or idle process name goes in `catalog/fly-work-procs.json`.
- Redeploy the `lane-run` image after the merge (`flyctl deploy . -c
  fly/lane-run.toml --build-only --push --image-label latest`). It now
  installs `procps`. Until a machine runs the new image, its probe fails, it is
  `unknown`, and it is not stopped.
