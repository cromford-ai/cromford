# Four side lanes skip the watchdog call when WATCHDOG_URL is unset (BH-3322)

Doc: OPERATOR-SETUP

## What changed

`bin/fleet-status-push.sh`, `bin/cost-rollup.sh`, `bin/progress-push.sh` and
`bin/state-restore.sh --standby` no longer fall back to the fleet watchdog
host. Each one resolves the URL through `watchdog_url` in
`bin/lib/watchdog-url.sh` (BH-3320). The value comes from `WATCHDOG_URL` in
`env/global.env`, which `bin/harness-sync.sh` seeds on this fleet.

When `WATCHDOG_URL` is unset or empty, only the watchdog HTTP call is skipped.
The rest of each lane runs as before, and `logs/watchdog-url.log` gets one line
per lane per UTC day.

- **fleet-status-push:** no status POST and no standby GET. The console beat
  is still sent. Its `standby_error` reads `unconfigured`, which is a new value
  next to `unreachable`, `nonjson` and `shape`. "Not configured" and "could not
  ask" stay distinct.
- **cost-rollup:** `logs/agent-rules.log` says
  `WATCHDOG_URL not set, cost snapshot NOT pushed`. That is not a FAILED line,
  and it raises no alert. The rollup reads `WATCHDOG_URL` from `env/global.env`
  at the push, because the script only loads that file later on.
- **progress-push:** no POST. The tick line in `logs/progress-push.log` says
  `watchdog=skipped: WATCHDOG_URL not set`.
- **state-restore --standby:** prints
  `standby report skipped: WATCHDOG_URL not configured`. The hub heartbeat
  (`standby-heartbeat.sh`) still runs.

The `WATCHDOG_URL` knob objects in `catalog/lanes.d/{fleet-status-push,cost-rollup,progress-push}.json`
are gone. The lib's `_lib.watchdog-url.json` owns the knob.

## Operator notes

If the hub's `env/global.env` has no `WATCHDOG_URL=` line when this lands,
fleet-status-push stops feeding the watchdog's dead-man and the worker pages.
A standby with no line stops reporting its stream. Check each box with
`grep -c '^WATCHDOG_URL=.' env/global.env` (it should print 1 or more), or look
for `WATCHDOG_URL seeded` in `logs/update-runners.log`.
