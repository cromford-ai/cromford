# BH-9889 C0: pool env bundle from a hub cache, and a loud restart lever

Date: 2026-11-22. Ticket: BH-9889 (slice C0 of 2).

## Why

A watcher box went dark. Every pool spawn for its projects died with
`ssh env extract from <ip> failed (ssh rc 255)`, and each job stayed queued.
The hub had shipped the same bundle a few minutes before. The restart lever
(`bin/box-ops.sh restart`) refused every box, because `ORGO_API_KEY` was not
set on the hub, and the refusal was one stderr line that nobody read.

## What changed

1. Hub cache (`bin/fly-envbundle.sh`, `--pool` with env `ENVBUNDLE_HUB_CACHE=1`).
   - Only the spawn call in `bin/fly-pool.sh` sets the flag. The other `--pool`
     callers (`bin/fly-pool-secrets-sync.sh`, `bin/fly-pool-rollout.sh`,
     `bin/lib/docker-pool-host.sh`) do not, so they never read or write the
     cache: a stale bundle must not reach Fly secrets or a rollout. Test C19.
   - A good ssh extract writes the raw extract stream to
     `$HARNESS/state/bundle-cache/<project>.raw` (state path class `cache`,
     `catalog/state-paths.d/9889-bundle-cache.json`). Dir mode 700, file mode 600.
   - The cache is NOT in the env dir. `bin/harden-state.sh` sets `chattr +i` on
     every file under the env dir every 10 min, so the next `mv` fails and the
     cache freezes at its first write. `bin/audit-tail.sh` also pages critical
     on every write under `/etc/harness`. Test C18 pins the location and a
     refresh over an older cache.
   - `bin/transcript-scrub.sh` reads secret values from the env dir only, so it
     does not scrub values that exist only in this cache. Nothing prints the
     cache content.
   - The write happens after every bundle check passed. A cached run never
     rewrites the file, so its age is the age of the last real extract.
   - When ssh exits 255 (the box did not answer), a cache file serves the
     bundle when it is a regular file, mode 600, not empty, and younger than
     the max age. stderr gets one line:
     `WARN: env bundle from hub cache (box unreachable): ssh rc 255 from <ip>, cache age <h>h of <max>h`.
     fly-pool.sh writes it to the pool log.
   - Any other ssh rc means the box answered and its extract failed. That stays
     FATAL, so a stale bundle cannot hide a real config fault.
   - A miss prints one `WARN: hub cache not used: <why>` line, then the FATAL of
     today. `pool_bundle_reason` in fly-pool.sh still reads the FATAL.
   - fly-dispatch (no flag), `--hub-global`, a local extract, a `--pool` call
     without the flag and the ssh-off guard never read or write the cache.
2. Knob: settings row `pool.env_bundle_cache_max_h` (seed `24`; 0..168;
   `0` = off). No row: env `POOL_ENV_BUNDLE_CACHE_MAX_H`, then 24. A bad value
   reads 24 with one WARN (`... = '<v>' is not 0..168; cache max age 24h`).
   The knob is read lazily: only on the ssh rc 255 branch and before the write
   after a good extract. When the ssh-off guard's settings read failed, the
   knob is not read again: it takes the fallback with no request and no line,
   so one settings outage stays one `read failed` line
   (`tests/fly-envbundle-ssh-off.bh-8316-test.sh` case C). A knob read that
   fails on its own prints `settings row pool.env_bundle_cache_max_h
   unreadable; cache max age 24h` (no `read failed` text). Registry:
   `catalog/lanes.d/fly-pool.knobs.d/POOL_ENV_BUNDLE_CACHE_MAX_H.json`.
3. Loud lever (`bin/lib/orgo-lever.sh`, `bin/lib/box-ops-orgo.sh`). On
   `--apply` with the Orgo key unset, box-ops writes one warn alert with
   `--id orgo-lever-<KEYENV>`, then refuses as before (rc 2,
   `not configured: <KEYENV> unset`). A dry run writes no alert. The text:
   `[orgo-lever] restart lever dead on <host>: <KEYENV> is not set. ...`

4. Off-box backup (`bin/state-backup.sh`). The cache holds plaintext env
   values, so the R2 state backup excludes `state/bundle-cache/` from its tar
   and its manifest. The leak check refuses any `state/bundle-cache` entry the
   same as a plaintext `env/` entry: nothing uploads, one leak-check alert.
   A restore does not need the cache.

## Retention

One file per project, overwritten in place. The count is bounded by the
project count, so no retention job applies.

## Left for C1

- The box-watch duty: lane, probes, restart in a window, recovery, action rows,
  page rules, the `/staff/quartermaster` section, kill switch `lane-off-box-watch`.
- The hourly lever check: `ORGO_API_KEY` is set and an Orgo read answers 200.
  It must use `orgo_lever_text` / `orgo_lever_alert` from `bin/lib/orgo-lever.sh`,
  so the operator sees one alert row.
- Prior code for C1 is on `origin/ticket/bh-9889-r3`.

## Tests

- `tests/fly-envbundle-hub-cache.bh-9889-test.sh`
- `tests/box-ops-orgo-lever.bh-9889-test.sh`
- `tests/state-backup-bundle-cache.bh-9889-test.sh`
