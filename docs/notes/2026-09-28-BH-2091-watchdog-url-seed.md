# WATCHDOG_URL is seeded into env/global.env from the repo (BH-2091, BH-3320)

Doc: OPERATOR-SETUP

## Why

Nine scripts read `${WATCHDOG_URL:-<fleet host>}` (watchdog-ping, progress-push,
fleet-status-push, tickets-snapshot-push, cost-rollup, watchdog-poll,
state-restore, harness-ctl, mac-burn-push). The later BH-2091 children drop that
hard-coded default. A box with no `WATCHDOG_URL=` line in `env/global.env` would
then stop calling the watchdog, and nothing would say so. This change lands
first so that line is already there on every box before any caller changes.

## What changed

- `catalog/fleet-watchdog.json` holds this fleet's worker URL and the repo that
  owns it (`example-org/cromford`). The URL is the same value
  `bin/watchdog-ping.sh` hard-codes today, so behavior does not change.
- `bin/lib/watchdog-url.sh` has three functions:
  - `watchdog_url <lane> <harness-root> [log-file]` prints `$WATCHDOG_URL`, with
    one trailing `/` stripped. When it is empty, it makes no call, writes one
    line per lane per UTC day to `logs/watchdog-url.log` and returns 1. No
    caller uses it yet.
  - `watchdog_url_carry <checkout>` prints the catalog URL only when the
    checkout's `origin` is `example-org/cromford` (https, ssh or
    credentialed, any case). A fork gets nothing, so it never sends its shared
    secret to our worker.
  - `watchdog_url_seed` appends `WATCHDOG_URL=<url>` to `env/global.env`. It
    takes `locks/harden-state.lock` and does `harden-state.sh --release` /
    `--rearm` around the append.
- `bin/harness-sync.sh` runs the seed on every deploy, just before the
  `catalog/` and `bin/` rsync. It never fails the deploy.
- The knob is registered as lib `watchdog-url` in
  `catalog/lanes.d/_lib.watchdog-url.json`, default `""`, `settable:false`.
  It can't be set from the control plane because a root lane sends the shared
  secret to that host.

## Operator notes

- **Your own value wins.** If `env/global.env` already has a non-empty
  `WATCHDOG_URL=` line, the seed leaves the file alone. An empty
  `WATCHDOG_URL=` line doesn't count: the seed appends after it, and the later
  line wins when the file is sourced.
- **No `env/global.env`, a fork, or no `origin`:** the seed does nothing.
- **Success** writes one line to `logs/update-runners.log`:
  `harness sync: WATCHDOG_URL seeded into env/global.env from catalog/fleet-watchdog.json (BH-2091)`.
- **ALERTS line `harness sync: could not append WATCHDOG_URL to …`** means the
  append failed (file still immutable, lock held for 60 s, disk). The deploy
  went ahead anyway. Fix it by hand: `bin/harden-state.sh --release <file>`,
  add the `WATCHDOG_URL=` line with the value from `catalog/fleet-watchdog.json`,
  then `bin/harden-state.sh --rearm <file>`. The next sync also retries on its
  own.
