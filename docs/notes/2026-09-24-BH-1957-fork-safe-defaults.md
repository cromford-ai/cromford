# An empty JOBS_URL is "not configured", the watchdog box list is config, and a failed merge-queue touch pages

Doc: OPERATOR-SETUP, DB-COORDINATION-SPEC

## What changed

- **`JOBS_URL=` (empty) means no coordination DB.** `bin/lib/jobs/req.sh`
  used `${JOBS_URL:-<fleet worker>}`, so an empty value still sent every call,
  HARNESS_SECRET included, to the fleet's harness-jobs worker. An empty value,
  whether it comes from the environment or from a `JOBS_URL=` line in global.env,
  now fails every request open (rc 1, no curl). It writes one line per UTC day to
  `logs/jobs-client.log` (flag `flags/alerted-jobs-not-configured-YYYYMMDD`) and
  never writes to ALERTS.log. The template fragment
  `env-templates/lanes/015-coordination-db.env.example` ships that empty line.
  `bin/fly-envbundle.sh` copies a box's `JOBS_URL=` line into the pool bundle
  exactly as written, empty value included.
- **UNSET still reaches the fleet worker, so item 10 is PARTIAL.** The ticket
  asks for no literal default and for UNSET to mean "not configured". This
  change delivers that only for an EMPTY value. Pool machines have no JOBS_URL
  today, so the literal stays as the fallback for an unset variable, and a fork
  whose global.env has no JOBS_URL line still sends its HARNESS_SECRET to our
  worker. #2063 removes the literal once every box's global.env and bundle carry
  JOBS_URL, and flips `tests/fork-defaults.bh-1957-test.sh` §5 to match.
- **The watchdog box list is `worker/watchdog/src/boxes.json`.** `index.js`
  imports that file. It no longer holds a `const BOXES` array.
  `docs/OPERATOR-SETUP.md` now tells a fork to edit `boxes.json` and says an
  unknown pinger pages. `tests/watchdog-boxes-test.sh` reads the file with `jq`
  and also fails if a box name other than `HUB` shows up as a literal in
  `index.js`.
  An authed `/api/ping/<box>` from a name missing from `boxes.json` still gets
  stored and still answers `ok`, but it now sends a Telegram alert, damped to
  one per hour by the `alerted:unknown:<box>` key.
- **Touch-mode merge-queue hand-off.** `bin/fly-pool.sh` `mq_touch` tries the
  ssh touch twice. If both tries fail it sends one `mergetouch` alert per project
  per day. That alert carries the rc and the exact command to run by hand, and
  fly-pool.log says `FAILED rc=N` instead of "sent".
- **`RR_ALERT` (bin/lib/rt/staging.sh)** now has a comment saying the dedup is
  per project per tag per day, not per row, and that a second failing row only
  shows up in `logs/<project>.log`.

## Why

BH-232 items 6, 8 and 13, and item 10 in part (see above). Item 9 (identical first lines merging two
close-outs) was already fixed on main by ebe5b450 (BH-1041).
`tests/relay-identity.bh-1957-test.sh` §2/§3 now pin that fix.
