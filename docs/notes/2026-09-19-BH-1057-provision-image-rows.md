# 2026-09-19 — BH-1057: the two one-shot Fly state writers now write their DB twin

Doc: DB-COORDINATION-SPEC

## What changed

Two scripts each gained one hook, after the file write they already did:

- `bin/fly-provision.sh` — after `log "wrote $STATE_FILE"` it sources
  `bin/jobs-client.sh` (guarded) and, when `machines_rows_on` says on and the
  machine id is non-empty, sends one `machine_put <project> <app> <mid> builder
  "" "" "" <image> stopped`. `stopped` is right because step 5 stops the machine
  it just ran; the sibling observe verb reconciles live state later.
- `bin/fly-image-refresh.sh` — after `echo "$IMG" > state/fly/<p>.image` it
  sends `setting_set fly_image.<p> <ref>`. The image ref is a per-project deploy
  pointer and a pool-routed project has no builder row to carry it, so its twin
  is a settings row, not a machines row.

Both scripts also took the `${HARNESS:-/root/harness}` seam so a test can drive
them verbatim against a scratch root (cron sets `HARNESS` nowhere, so production
resolves to exactly the same path it did before). `bin/fly-provision.sh` now
reads `state/fly/<p>.image` through `$STATE_DIR` instead of the hardcoded path —
same file, same path in production.

## Why

Parent #1035: the file under `state/fly/` is the only record that a builder
machine or a pool image exists, and it lives on one box. The row is its twin, so
the coordination DB can answer "what machines do we have" without ssh. The file
stays authoritative; the row is a side channel.

## The order and the failure mode

File first, row second, fail-open. A worker that is down, refuses, or has
`fly_machines_rows` off never changes either script's exit code and never
changes what lands on disk. The two log lines this adds:

- `machines row not written (worker unreachable or refused) — state file is authoritative this cycle`
  (stdout of `fly-provision.sh`)
- `<p> image row not written (worker unreachable or refused) — state/fly/<p>.image is authoritative this cycle`
  (`logs/fly-image-refresh.log`)

Each fires only when the flag said ON and the write then failed. A flag that
could not be read at all is a silent skip — `machines_rows_on` answers rc 1 and
`bin/jobs-client.sh` logs the transport failure in its own log. A project name
outside `^[a-z0-9_.-]+$` fails `_setting_key_ok` inside `setting_set`, costs no
request, and lands on the same "not written" line.

## What is NOT wired

`bin/fly-pool-rollout.sh` and `bin/fly-image-build.sh` also write image state and
are deliberately untouched by this slice. So are `bin/fly-pool.sh`,
`bin/fly-pool-tick.sh`, `bin/jobs-client.sh` and the worker. No reader switched:
every consumer still reads the file.

## Turning it on

The flag is a DB row, `fly_machines_rows`, seeded `off` in
`worker/jobs/schema.sql`. Flip it with `bin/jobs-client.sh setting-set
fly_machines_rows on`, or set `FLY_MACHINES_ROWS=on` in the caller's environment
to override on one box.

**THE FLAG IS THE ONLY THING BETWEEN THESE WRITERS AND A ROW.** `PUT /api/settings`
has been live on the worker since BH-283, and `PUT /api/machines` ships in this
same PR (BH-1055). So flipping `fly_machines_rows` to `on` is not inert: the
05:40Z `fly-image-refresh` cron writes `fly_image.<p>` settings rows on its next
run, and the next `fly-provision` writes a builder machine row, as soon as
`harness-sync.sh` has deployed this worker. Flip it when you mean to start
recording, not to "pre-flip". With the flag on,
`bin/jobs-client.sh machines-list <p>` shows the builder row and
`bin/jobs-client.sh setting-get fly_image.<p>` shows the image ref; with it off
every writer logs its "not written" line and changes nothing else.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/fly-machines-rows-provision.bh-1057-test.sh`
drives both real scripts against a scratch `$HARNESS` with a recording `curl`
and `flyctl`, and asserts the file existed at the moment the request went out.
