# MKF-1 (BH-8316): pool spawns for project-6-os take no ssh to project-6-os

Ticket: BH-8316 (MKF-1, part of #8315).
Spec: `docs/notes/2026-10-19-BH-7430-pool-secrets-sync.md` (the BH-7430 pull path).
Doc: none

## What changed

One guard in `bin/fly-envbundle.sh`, `envbundle_ssh_guard`. It runs only on
the ssh branch: the project's owning box is not `local`. It runs just before the
`ssh` call.

| step | source | answer |
|---|---|---|
| 1 | settings row `pool.envbundle_ssh.<project>` (`setting_get`) | the value |
| 2 | no row (rc 2): env `POOL_ENVBUNDLE_SSH` (knob in `catalog/lanes.d/fly-pool.knobs.d/`) | the value |
| 3 | no env | `on` |

The value is trimmed and folded to lower case. Only `off` refuses. Every other
value (`on`, `of`, `off-later`, `0`, empty) runs the extract as before.

With `off`:

- `bin/fly-envbundle.sh` makes 0 ssh calls and writes no bundle file.
- It writes one ALERTS line through `bin/alert-line.sh --id envbundle-ssh-off-<project>`:
  `[fly-envbundle/<project>] push path refused: ssh off (settings row pool.envbundle_ssh.<project>=off) ...`
- It exits 1 with `FATAL: push path refused: ssh off (settings row pool.envbundle_ssh.<project>)`.
- `pool_bundle_reason` in `bin/fly-pool.sh` makes that FATAL the unclaim reason.
  The job stays queued. No budget is used.

A failed row read (worker outage, no secret, no `JOBS_URL`) fails open. The
extract runs as before, and stderr gets one line:
`fly-envbundle/<project> WARN: settings row pool.envbundle_ssh.<project> read failed; ssh extract runs as before`.
The pool writes that stderr to `logs/fly-pool.log`.

Why: when the pull path is on, a spawn that falls back to the push path does an
ssh extract from the owning box (project-6-os for project-6-os) again. Before this
guard, that fallback was one `push path (<why>)` line in `logs/fly-pool.log` and
nothing else. With the row `off`, the fallback stops and pages.

The guard applies to every caller on the ssh branch: the pool spawn,
`bin/fly-dispatch.sh`, the rollout smoke and `bin/fly-pool-secrets-sync.sh`.
So a secrets re-sync with the row `off` is refused too (step 7 below).

## Operator steps for pool-project-6-os

These need Fly, the hub and a prod settings write. A build box cannot do them.

1. Bake a new pool-project-6-os image that carries `/opt/fly-boot/harness-fetch.sh`:
   `bin/fly-image-build.sh project-6-os` on the hub.
2. On the hub, run `fly machine run --help | grep -- --file-local`. It must
   print a line. If it prints nothing, stop. Keep `machine_pull` at 0.
3. Run the pull probe against a THROWAWAY test app, never against
   pool-project-6-os: `bin/fly-pool-probe-pull.sh <test-app> <image from step 1>`.
   It must exit 0.
4. Run `bin/fly-pool-secrets-sync.sh project-6-os --dry-run`, check the names,
   then run `bin/fly-pool-secrets-sync.sh project-6-os`. Confirm
   `HBUNDLE_SYNCED_AT` with `fly secrets list -a pool-project-6-os`.
5. Set the row `lane.fly-pool.project-6-os.machine_pull` to `1`.
6. Read `logs/fly-pool.log` on the hub. 3 project-6-os spawns must log
   `spawned <mid> for <key> (pull, live=...)`, and each build must reach RESULT.
   If one does not, set `machine_pull` back to `0` and stop.
7. Set the row `pool.envbundle_ssh.project-6-os` to `off`. For a later secrets
   re-sync: set it to `on`, run step 4, then set it to `off` again.
8. After 24 h with the row `off`, run on the hub:
   `grep project-6-os logs/fly-pool.log | grep -c -e 'env bundle FAILED' -e 'push path'`.
   It must print 0.

## How to read the signals

- `grep 'push path refused: ssh off' logs/ALERTS.log`: a spawn asked for the
  ssh extract while the row was `off`. Read the `push path (<why>)` line for the
  same key in `logs/fly-pool.log`. It names the missing pull precondition.
- `grep 'pool.envbundle_ssh' logs/fly-pool.log | grep 'read failed'`: the row
  could not be read, so the ssh extract ran. Check the worker and
  `HARNESS_SECRET`.

## Tests

`tests/fly-envbundle-ssh-off.bh-8316-test.sh`: row `off` refuses (rc 1,
0 ssh, 1 ALERTS line), ` OFF ` refuses, no row and non-`off` values run, a
failed read fails open with one WARN, a `local` box ignores the row, the env
fallback and the row-over-env order, the `pool_bundle_reason` round trip, and
no fixture secret in any output. ssh and curl are shims. No network.
