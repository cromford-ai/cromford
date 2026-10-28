# MKF-8 (BH-8323): provision box-mkfly and run it in shadow

Ticket: BH-8323 (MKF-8, part of #8315, order 8 of 10).
Spec: `docs/notes/2026-10-25-BH-8322-MKF-7-box-move.md` (provision, seed,
no-write tick, proof) and `docs/notes/2026-10-26-BH-8410-box-move-cutover.md`
(cutover B1 reads the shadow ticks this stage writes).
Doc: HUB-THINNING-PLAN, RESTORE

## What changed

No code. This note is the operator runbook for MKF-8. It provisions the Fly
machine `box-mkfly`, seeds it from `box-project-6-os-1`, and runs
no-write shadow ticks on it for 24 h. Every command is an existing
`bin/box-move.sh` verb (BH-8322) or a read-only probe.

These steps need the hub, Fly, the tailnet, the backup bucket and the project-6-os env.
A build box cannot run them. Until an operator posts the results table (step 7)
on #8323, the rung is BUILT (this note), not provisioned.

## What MKF-8 does NOT do

- No `cutover`, no `rollback --confirm`, no `bin/registry.sh` write, no
  `bin/box-register.sh`. `box-register.sh <id> --project <p>` MOVES the
  project row, so it is the cutover. That is MKF-9 (#8324), cutover step B4.
- No `cron/boxes/mkfly.d`. The new machine keeps the project-6-os box id, so
  `bin/render-cron.sh <box id>` renders the project-6-os crontab there (MKF-7 "Rules").
  A second fragment would render a second crontab under a new id.
- No edit of the registry `boxes` lists. MKF-9 adds the new host to them after
  B4: L5 `box_aliases`, L7 `worker/watchdog/src/boxes.json`, and L8
  `TAILNET_IPS` (redaction) when the tailnet IP is quoted. An entry in L7 now
  would make the watchdog alert a box that has no crontab on every tick.
- No `crontab -r`, no `all-off` and no file write on project-6-os.

## Machine shape

The ticket asks for performance-4x, 8 GB and a 60 GB volume. Set them on the
command line. The `bin/box-move.sh` fallbacks stay as they are (the volume
fallback is 100 GB). project-6-os uses about 45 GB (99 GB disk, 45% used), so 60 GB fits.

```bash
export BOX_MOVE_VM_SIZE=performance-4x BOX_MOVE_MEM_MB=8192 BOX_MOVE_VOLUME_GB=60
export BOX_MOVE_IMAGE=<hub image>
```

`<hub image>` is the image ref the hub runs (MKF-7 probe text). Read it from
the hub app with `flyctl image show -a <hub app>` and copy the `registry.fly.io/...`
ref. Do not use a tag from this note.

## Operator steps

Run every step on the hub, from `/root/harness`, in the same shell (the
exports above stay set). `O=box-project-6-os-1 N=box-mkfly`.

1. Preconditions. Each one must pass. If one fails, stop.
   1. The MKF-6 backup exists. On project-6-os:
      `bin/state-restore.sh "$(tr -dc 'a-z0-9-' < state/box-id)"` prints one
      or more `<ts>  <bytes>` rows. (`state-restore.sh` has no `list` verb; the
      listing is the box id with no ts, MKF-6 section 5.)
   2. `TS_AUTHKEY_BOX` is a set line in `fly.env` on the hub (name only):
      `. bin/lib/env-path.sh; grep -c '^TS_AUTHKEY_BOX=.' "$(harness_env_dir)/fly.env"` prints 1.
   3. `jq -r '.prefixes["box-"].source' catalog/fly-idle-signals.json`
      reads `exempt` (on main since BH-8322; provision refuses otherwise).
2. project-6-os BEFORE snapshot (acceptance test 3). Write it on the hub:
   ```bash
   mkdir -p state/box-move/$N
   OIP=$(bin/fleet-conf.sh --tailnet-ip-of-box $O)
   { ssh root@"$OIP" 'cd /root/harness; crontab -l 2>/dev/null | grep -vc "^[[:space:]]*#"; crontab -l 2>/dev/null | sha256sum; ls flags/; cat state/box-id'
     bin/fleet-conf.sh --projects-on-box $O; } > state/box-move/$N/project-6-os-before.txt
   ```
   It holds counts, a hash, flag names, the box id and project names. No value.
3. Box move, in this order. Stop at the first exit that is not 0.
   1. `bin/box-move.sh inventory box-project-6-os-1 box-mkfly`
   2. `bin/box-move.sh provision --plan box-project-6-os-1 box-mkfly`.
      It prints `PLAN provision 1/6` to `6/6` and calls nothing. Line 5/6 must
      show `--vm-size performance-4x --vm-memory 8192`. Line 2/6 must show
      `volume box_data 60 GB`.
   3. `bin/box-move.sh provision box-project-6-os-1 box-mkfly`.
      It writes `state/box-move/box-mkfly/target.json`. Check
      `jq -r .size state/box-move/$N/target.json` reads `performance-4x/8192MB/60GB`.
   4. `bin/box-move.sh seed box-project-6-os-1 box-mkfly latest`.
      mkfly ends with a LOCAL `flags/all-off` and no crontab.
   5. `bin/box-move.sh tick box-project-6-os-1 box-mkfly`, the first
      shadow tick. Exit 4 means the tick rc was not 0: read the table, do not
      go on to cutover.
4. Shadow ticks for 24 h. Run step 3.5 again about every 6 h, 4 or more runs
   in total, the last one less than 24 h before MKF-9 starts
   (`BOX_MOVE_TICK_MAX_AGE_S`, 86400, is the oldest tick cutover B1 accepts).
   Run them by hand or from one loop in a tmux on the hub:
   ```bash
   for i in 1 2 3; do sleep 21600; bin/box-move.sh tick box-project-6-os-1 box-mkfly; done
   ```
   This is not a cron line or a lane: box-move is operator-run (BH-8322). Each
   run writes its own `state/box-move/box-mkfly/tick-<ts>.tsv` and
   `tick-<ts>.summary`. A held lock prints and exits 0; run it again later.
5. `bin/box-move.sh proof box-project-6-os-1 box-mkfly`. It prints
   the mkfly load per vCPU, 0 active crontab lines, `all-off` on, the newest
   tick summary, and the projects the rows put on each box (all still on project-6-os).
6. Reach probes (acceptance test 2). Each prints a status code, a count or an
   rc, never a value.
   1. Hub to mkfly over the tailnet:
      ```bash
      NIP=$(jq -r .ts_ip state/box-move/$N/target.json)
      ssh -o ConnectTimeout=15 root@"$NIP" true; echo "hub->mkfly ssh rc=$?"
      ```
   2. mkfly to the jobs worker, GitHub and the Fly API:
      ```bash
      ssh root@"$NIP" bash -s <<'EOF'
      cd /root/harness
      JOBS_SETTINGS_CACHE_S=0 bin/jobs-client.sh setting-get box_move.reach_probe >/dev/null 2>&1; echo "jobs rc=$?"
      gh api rate_limit -q .rate.remaining >/dev/null 2>&1; echo "github rc=$?"
      ( . bin/lib/env-path.sh; set -a; . "$(harness_env_dir)/fly.env" 2>/dev/null; set +a
        flyctl apps list --json >/dev/null 2>&1; echo "fly api rc=$?" )
      EOF
      ```
      Pass: `hub->mkfly ssh rc=0`, `jobs rc=0` or `jobs rc=2`, `github rc=0`,
      `fly api rc=0`. `jobs rc=2` is a pass: the worker answered an
      authenticated request and the key has no row. `jobs rc=1` is a fail: no
      transport, no secret, or the worker refused the bearer.
   3. Each tick table carries line 2 `# reach ssh=<rc> flyctl=<rc> host=<h>`
      (`hmr_reach_run`). Cutover B1 needs `ssh=0 flyctl=0` on the newest one.
7. project-6-os AFTER snapshot. Run the step 2 block again into
   `state/box-move/$N/project-6-os-after.txt`, then
   `diff state/box-move/$N/project-6-os-before.txt state/box-move/$N/project-6-os-after.txt; echo "diff rc=$?"`.
   It must print `diff rc=0` with no lines. A new flag, a changed crontab hash or
   a project that moved is a fail: stop and post it on #8323.
8. Post the results table below on #8323 and attach every `tick-*.tsv`.

## Reading a tick table

`tick-<ts>.tsv`: line 1 `# mode=nowrite at=<epoch>`, line 2 the reach line,
then `lane rc secs refused timed_out`. A lane passes when `rc` is 0, or when it
is a named skip: `refused` 1 (the no-write shim refused a write) or `timed_out`
1. Every other row with `rc` not 0 is a fail. This is the rule cutover B1
applies to the newest table. List the failed lanes:

```bash
f=$(ls state/box-move/box-mkfly/tick-*.tsv | tail -1)
grep -v '^#' "$f" | tail -n +2 | awk -F'\t' '$2 != 0 && $4 == 0 && $5 == 0 {print $1 "(rc=" $2 ")"}'
```

A failed lane is fixed before MKF-9, or named in `BOX_MOVE_B1_ALLOW` there with
the reason on #8323.

## Results table (post on #8323)

| Item | Value |
|---|---|
| provision `target.json` `.size` | |
| seed exit | |
| tick 1: file, summary line, failed lanes | |
| tick 2: file, summary line, failed lanes | |
| tick 3: file, summary line, failed lanes | |
| tick 4: file, summary line, failed lanes | |
| newest tick reach line (`ssh= flyctl=`) | |
| proof: load5_per_vcpu, active crontab lines, all-off | |
| hub->mkfly ssh rc | |
| jobs rc / github rc / fly api rc (from mkfly) | |
| project-6-os before/after `diff rc` (lines, if any) | |

## Rollback for this stage

project-6-os was never touched, so there is nothing to put back there. mkfly has a
LOCAL `all-off` and no crontab, so it runs no lane. To stop the machine too:

```bash
flyctl machine stop -a box-mkfly "$(jq -r .machine_id state/box-move/box-mkfly/target.json)"
```

Do not run `bin/box-move.sh rollback`: it is for after cutover B2 and refuses
(exit 3) before it. Do not destroy the volume: a later MKF-8 re-run finds it
(find-before-create) and reuses it.

## Status

| Item | Rung | What is still owed |
|---|---|---|
| Runbook | BUILT: this note | none |
| Provision and seed | not started | an operator runs steps 1-3 |
| 24 h shadow ticks (AC 1) | not started | an operator runs steps 4-5 and attaches the tick files |
| Reach (AC 2) | not started | an operator runs step 6 |
| project-6-os unchanged (AC 3) | not started | an operator runs steps 2 and 7 |
