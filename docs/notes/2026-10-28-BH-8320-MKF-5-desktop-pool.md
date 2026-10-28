# MKF-5 (BH-8320): project-6-desktop builds on its own Fly pool

Ticket: BH-8320 (MKF-5, part of #8315, order 5 of 10).
Spec: `docs/notes/2026-10-25-BH-8319-project-rust-bake.md` (the rust bake rows),
`docs/notes/2026-10-28-BH-8318-pool-vm-size.md` (the VM rows),
`docs/notes/2026-10-25-MKF-1-pull-path-project-6.md` (the pull path and the ssh-off guard),
`docs/notes/2026-10-25-BH-8317-secret-store.md` (the Fly-secret store).
Doc: FLY-POOL, FLY-BUILDER-TRIAL

## What changed

No code. This note is the operator runbook that puts project-6-desktop on the
pool app `pool-project-6-desktop`. Every value it sets is a settings row that
already exists. Every command it runs is an existing script.

Today `fleet.conf` line 79 puts project-6-desktop on `box-project-6-os-1`. Its
cargo builds run on project-6-os and load that box. After step 2 writes
`flags/builder-fly-project-6-desktop` on the hub, its builds go to the pool, not
to project-6-os.

## Why the order matters

`bin/fly-onboard.sh` wraps `bin/fly-pool-rollout.sh`. The rollout rebakes the
image through `bin/fly-image-build.sh`, runs a live SMOKE, and writes
`flags/fly-pool-project-6-desktop` and `flags/builder-fly-project-6-desktop`
only on SMOKE_OK. `bin/fly-image-build.sh` reads `bake.project-6-desktop.rust.version`
at bake time. With no row, the image has no cargo, and the SMOKE does not run
cargo. So the routing flag goes on for an image that cannot build the project.
The bake rows MUST exist before the onboard runs.

For the same reason, do NOT add a `project-6-desktop` line to
`fly/onboard-queue.conf`. `bin/fly-pool-tick.sh` drains that queue on the hub
after a merge, maybe before step 1. It is also a shared list (build discipline:
no shared list append).

## Operator steps

These need the hub, Fly and prod settings writes. A build box cannot do them.
Run every command from `/root/harness` on the hub. Raw rows go through
`setting_set` in `bin/jobs-client.sh`:

```
. bin/jobs-client.sh
setting_set <key> <value> "BH-8320"
```

0. Preconditions.
   1. PR #8288 (BH-8281, the cargo cap on project-6-os) is merged or closed. Merge is the
      recommended choice: the cap is the on-box fallback if the Fly flag is
      removed (step 6).
   2. BH-8318 is merged and deployed on the hub:
      `grep -c pool_vm_resolve bin/fly-pool.sh` prints 1 or more.
   3. BH-8319 is deployed on the hub:
      `grep -c bake_project_resolve bin/fly-image-build.sh` prints 1 or more.
1. Rows before the bake.
   1. Find the Rust version. Use the exact x.y.z in project-6-desktop's
      `rust-toolchain.toml`. If that file does not exist, use the version that
      `cargo --version` prints on project-6-os. A value with no exact x.y.z (`stable`,
      `1.90`) refuses the bake.
   2. `setting_set bake.project-6-desktop.rust.version <x.y.z> "BH-8320"`
   3. `setting_set bake.project-6-desktop.webkit.version <x.y.z> "BH-8320"`.
      Tauri needs both (BH-8319). Use the upstream webkit2gtk version that the
      project-6-os build uses.
   4. `bin/harness-ctl.sh set fly-pool VM_SIZE performance-16x project-6-desktop`
      (row `lane.fly-pool.project-6-desktop.vm_size`).
   5. `bin/harness-ctl.sh set fly-pool VM_MEMORY_MB 32768 project-6-desktop`
      (row `lane.fly-pool.project-6-desktop.vm_memory_mb`). 32768 is in the
      performance-16x range (32768..131072).
2. Onboard. Run `bin/fly-onboard.sh project-6-desktop --cap 1` (one 16x machine
   at a time). Expect:
   - `FLY_ONBOARD project-6-desktop OK: ...` on stdout and in `logs/fly-pool-rollout.log`.
   - `bake-pin: rust <x.y.z>` in `logs/fly-image-build.log`.
   - The file `flags/builder-fly-project-6-desktop` exists.
   If the verdict is `FAILED`, stop. No routing flag is written, and builds stay
   on project-6-os.
3. Secrets and pull path. Do the steps of the two notes below, with
   `project-6-desktop` in place of `project-6-os`. Do not copy the steps here;
   the notes are the source.
   1. MKF-2 runbook steps 1-6 (`docs/notes/2026-10-25-BH-8317-secret-store.md`):
      the ssh-mode `bin/fly-pool-secrets-sync.sh project-6-desktop`, then
      `bin/project-secrets.sh import project-6-desktop`, then
      `bin/fly-pool-secrets-sync.sh project-6-desktop --no-box` and
      `bin/project-secrets.sh verify project-6-desktop` (rc 0,
      `verify/project-6-desktop: ok (...)`). Step 4 of that runbook
      (QA_CLERK_*) applies only if `env/project-6-desktop.env` names them.
   2. MKF-1 steps 2-6 (`docs/notes/2026-10-25-MKF-1-pull-path-project-6.md`):
      the `--file-local` check, the pull probe against a THROWAWAY test app,
      then the pull row:
      `bin/harness-ctl.sh set fly-pool POOL_MACHINE_PULL 1 project-6-desktop`
      (row `lane.fly-pool.project-6-desktop.pool_machine_pull`). The image of
      step 2 already carries `harness-fetch.sh`. 3 project-6-desktop spawns must log
      `spawned <mid> for <key> (pull, live=...)` and reach RESULT. If one does
      not, set the row back to 0 and stop.
4. Ssh off. `setting_set pool.envbundle_ssh.project-6-desktop off "BH-8320"`.
   For a later secrets re-sync: set it to `on`, run step 3.1, then set it to
   `off` again (MKF-1 step 7).
5. Acceptance probes. Run the probes in the next section. Write their output
   in the PR or the ticket.
6. Rollback.
   1. `rm flags/builder-fly-project-6-desktop` on the hub. Builds go back to
      project-6-os, under the #8288 cap.
   2. `bin/harness-ctl.sh set fly-pool POOL_MACHINE_PULL 0 project-6-desktop`.
   3. `setting_set pool.envbundle_ssh.project-6-desktop on "BH-8320 rollback"`.

## Acceptance probes (live, operator)

- A1: One cargo build of project-6-desktop reaches RESULT on Fly while a project-6-os tick spawns, with 0 env-bundle failures. On the hub,
  `grep 'project-6-desktop' logs/fly-pool.log | grep 'spawned .* (pull'` shows
  the spawn, and the build dir of that key has a `RESULT` line. In the same time
  window, `grep project-6-os logs/fly-pool.log | grep 'spawned '` shows 1 spawn
  or more, and `grep -e project-6-os -e project-6-desktop logs/fly-pool.log | grep -c 'env bundle FAILED'`
  over that window prints 0.
- A2: project-6-os load5 stays under 4 during that build. On project-6-os, sample
  `cut -d' ' -f2 /proc/loadavg` every 60 s from the spawn line to RESULT.
  Every sample is below 4.
- A3: 7 days with 0 cargo processes on project-6-os. Once a day for 7 days, on project-6-os, run
  `pgrep -c -x cargo || true` with the run time of `bin/box-self-report.sh`.
  Each sample prints 0. `bin/box-self-report.sh` has no cargo field today, so
  the pgrep line is the evidence.

## Known gaps

- `bin/pool-budget.sh` prices a machine-hour at 8 CPU / 16384 MB (BH-8318
  known gap). A performance-16x machine gets a low budget estimate.
- `fleet.conf` still names `box-project-6-os-1` as the owning box. The watcher
  and triage stay there. Only the builds move.
