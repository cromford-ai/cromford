# The Fly idle reaper lane (BH-6061)

Doc: COST, OPERATOR-SETUP

## What changed

- New hub lane `fly-idle-reaper` (`bin/fly-idle-reaper.sh`, cron
  `2-59/5 * * * *` in `cron/lanes/729-fly-idle-reaper.cron`, behind
  `hub-lease.sh check`). It ships ON. The kill switch is
  `flags/lane-off-fly-idle-reaper`.
- It lists every app the org token `FLY_API_TOKEN` sees, gives each app an idle
  signal from `catalog/fly-idle-signals.json` (pool, builder, testhost,
  exempt), and stops (never destroys) a started machine idle more than
  `fly.idle_stop_after_s`. Each stop writes a row to the jobs worker. The
  full rule is in `docs/verification-map/fly-idle-reaper.md`.
- `bh-ci-runners-example-org` is registered `exempt`: the BH-1210 warm minimum
  keeps started runners on purpose.
- A lane-run app (#6047) has no signal yet, because #6047 has no claim queue.
  It is never stopped, and it alerts after 1 h like any app with no signal.

## Operator setup

- The hub must have `FLY_API_TOKEN` (the org token `fly-idle-check` already
  reads) in its env files, and flyctl installed. Without the token the lane logs
  `not configured` and raises `fly-idle-reaper-unconfigured` once. `FLY_ORG`
  is optional. Without it the lane lists every app the token sees.
- To change a threshold, set a settings row: `fly.idle_stop_after_s`,
  `fly.idle_stop_after_s.<app>`, `fly.idle_nosignal_alert_s`,
  `fly.idle_fail_alert_after`, `fly.idle_max_stops_per_pass`.
- To give a new app family a signal, add it to
  `catalog/fly-idle-signals.json`. A new source kind needs code in the reaper.
