# Nightly red: two suite fixtures, and the nightly ticket opens labelled ai-build (BH-3411)

Doc: none (no contract doc changes; `bin/nightly-ticket.sh`'s header carries the label behaviour)

## What changed

Two nightly-tier suites went red on main after df92116. Neither red was a
product regression. Each was a fixture seam that a 2026-09-28 merge moved:

- `tests/lane-liveness-test.sh` (9 FAILs, section 1). BH-3223 made
  `tests/lib/scratch.sh` export `JOBS_URL=` empty, meaning "no worker here".
  `push_lanes()` never set a stub, so `_jobs_req` refused and the hub never
  sent `PUT /api/lanes`. `push_lanes()` now exports `JOBS_URL=https://jobs.invalid`
  like the file's other drivers. It also exports `FLEET_CONF="$T/fleet.conf"`,
  because `bin/fleet-conf.sh` reads `/root/harness/fleet.conf` first and on a
  harness box the suite was reading the real registry.
- `tests/routing-sweep-readers.bh-1027-test.sh` (3 FAILs, cases 2, 3, 5).
  BH-3322 removed the default watchdog host from `bin/fleet-status-push.sh`, so
  with `WATCHDOG_URL` unset the status POST the fake curl captures is skipped.
  The suite now sets `WATCHDOG_URL=https://harness-watchdog.invalid` and copies
  `bin/lib/watchdog-url.sh` in, the same patch BH-3322 gave ten sibling suites.

No assertion changed. Don't "fix" these by restoring a default `JOBS_URL` or
watchdog host in the code: both empties are deliberate prod-safety behaviour.

`bin/nightly-ticket.sh` now opens its ticket with `labels[]=ai-build`, so a red
nightly reaches a builder with no human step. GitHub drops labels on create for
a caller without push access, and it does so silently. So the script reads the
create answer back and, when `ai-build` is missing, POSTs it once to
`issues/<n>/labels`. If that is refused it exits 1 with
`opened #N but could not label it ai-build`, which the workflow turns into
`::error::`. Commenting on an already-open ticket never touches labels, so a
ticket a person unlabelled (HOLD, a split master) stays unlabelled.
`tests/nightly-ticket-label.bh-3411-test.sh` pins all of it.
