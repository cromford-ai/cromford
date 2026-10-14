# The fleet reads the D1 registry; fleet.conf is an export (BH-5651, wave 3 of BH-5633)

Doc: OPERATOR-SETUP, RESTORE

## What changed

1. **The switch.** `bin/harness-sync.sh` calls `registry_source_seed`
   (`bin/lib/registry-source-seed.sh`) right after `watchdog_url_seed`. It
   appends `REGISTRY_SOURCE=db` to `env/global.env` once, only when:
   - the file has no `REGISTRY_SOURCE=` line, and
   - one fresh `GET /api/registry` answers, and its active project set equals
     the checkout `fleet.conf`'s.

   If a check fails, the box stays in file mode and `logs/update-runners.log`
   gets one line a UTC day (`flags/registry-seed-wait-<day>`). A failed append
   writes one line through `bin/alert-line.sh`. A failed seed never fails the
   sync.
2. **The export.** New `bin/registry-export.sh`, with four modes:
   `--fleet-conf [--template f]`, `--cost-accounts --template f`,
   `--install <root> [--checkout d]` and `--snapshot <dir> [--keep N]`.
   `--install` replaces `$H/fleet.conf` and the box maps of
   `$H/catalog/cost-accounts.json` with a render of the registry, only in db
   mode and only when the bytes differ. It refuses a render whose project set
   is not the registry's active set.
3. **Who installs it.** `bin/harness-sync.sh` runs `--install` where it used to
   copy the committed `fleet.conf`. On rc 1 (file mode, no usable registry, a
   refused render) it copies the committed file as before.
   `bin/registry-sync.sh` runs `--install` every tick, so a stale
   `$H/fleet.conf` is repaired within one tick.
4. **The seed guard.** `bin/registry-seed.sh` asks
   `GET /api/registry/version` before it imports. Version 1 or more is rc 1
   with no POST, unless `--force`. Version 0, or 503
   `registry schema not applied`, proceeds. Any other answer is rc 1.
5. **Restore.** `bin/registry-seed.sh --from-export <dir|import.json>` posts a
   nightly snapshot's `import.json` to `POST /api/registry/import`. The same
   guard applies.
6. **The nightly lane.** `registry-export` (hub, `41 3 * * *`,
   `cron/lanes/382-registry-export.cron`) runs
   `bin/registry-export.sh --snapshot /root/harness/state/registry/export`. It
   keeps `REGISTRY_EXPORT_KEEP` snapshots (default 14). Three failed runs in a
   row write one ALERTS line. Off: `flags/lane-off-registry-export`.

## Why

Wave 1 (BH-5649) and wave 2 (BH-5650) put the registry in D1 and gave it
audited writes. The files stayed the input on every box. This wave makes D1
the one input and keeps the files as a generated export for humans and for
disaster recovery.

## Rules, state and commands it touches

- Kill switch: `REGISTRY_SOURCE=file` in `env/global.env`. The seed never
  changes an existing `REGISTRY_SOURCE=` line.
- Change a box or a project: `bin/registry.sh add-box`, `move-project`,
  `add-project`, `drain-box`. Do not edit `$H/fleet.conf` on a db box: the
  next `registry-sync` tick rewrites it.
- State: `state/registry/export/<YYYYmmddTHHMMSSZ>/` (`registry.json`,
  `import.json`, `fleet.conf`, `cost-accounts.json`),
  `state/registry/export/latest`, `state/registry/export/.fail-count`.
- Logs: `logs/registry.log` (install), `logs/registry-export.log` (snapshot),
  `logs/update-runners.log` (seed).
- Restore drill: `docs/RESTORE.md`, "Rebuilding the fleet registry (D1)".
