# BH-3323: the off-box WATCHDOG_URL callers read the catalog

Doc: OUTSIDE-DEADMAN

Part 4 of BH-2091. Two callers that do not run on a box's harness carried the
fleet watchdog host as a literal default, so a fork running them sent its
shared secret to this fleet's worker. Both now resolve the URL from
`catalog/fleet-watchdog.json`, behind the same origin/repo guard as the box
seed (`bin/lib/watchdog-url.sh`, BH-3320).

- `bin/mac/mac-burn-push.sh` (the operator's Mac, launchd hourly): an explicit
  `WATCHDOG_URL` still wins (one trailing `/` dropped). Empty, it sources
  `bin/lib/watchdog-url.sh` beside itself and takes `watchdog_url_carry` of
  `$MACBURN_CHECKOUT` (default `~/cromford`). Still empty: one
  `[mac-burn] WATCHDOG_URL not set` line per UTC day in `~/.mk-macburn.log`,
  no scan, no POST, rc 0. The lib missing beside the script is a loud log line
  and rc 1, like a missing price table. A Mac that runs only from another
  checkout needs `MACBURN_CHECKOUT` or `WATCHDOG_URL` set.
- `.github/workflows/publish-share.yml`, "Stamp the outside dead-man": the URL
  is the catalog's `watchdog_url` when `github.repository` equals its `repo`
  (case-insensitive). Otherwise the step prints `no fleet watchdog for this
  repo: no stamp` and exits 0. A missing `WATCHDOG_STAMP_SECRET` still prints
  its own message first. The step never fails the publish.
- `env-templates/lanes/020-watchdog-dead-man-ping.env.example`: `WATCHDOG_URL`
  is a commented example, with two lines saying empty means no watchdog calls
  and that this fleet's boxes get it seeded by harness-sync.

Pinned by `tests/watchdog-url-offbox.bh-2091-test.sh`.
