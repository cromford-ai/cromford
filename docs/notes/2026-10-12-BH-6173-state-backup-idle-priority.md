# State backup runs at idle priority, compresses at zstd -1 and skips unchanged inputs (BH-6173)

Doc: RESTORE

## What happened

On 2026-10-12 at 07:51Z the hub ran 8 vCPUs at 44% steal. A 20 s CPU sample
put `zstd` and `tar` from `bin/state-backup.sh` at the top of the "other"
share, with `zstd` at 69% of one CPU in `top`. The lane runs at minutes
5/20/35/50 on 11 boxes. It used the zstd CLI default (level 3) at normal
priority, and it compressed every input again on every run.

## What changed

1. **Idle priority.** Every heavy child of the lane runs under
   `nice -n 19 ionice -c3 -t`: the manifest `find`, the env `tar` and `age`,
   the archive `tar`, the listing `tar` and `sha256sum`. `-t` keeps the backup
   on a box whose I/O scheduler refuses the idle class. With no `ionice` on
   PATH the lane runs at nice 19 only and logs one line.
2. **zstd level.** The archive is written with
   `tar -I "zstd -<BACKUP_ZSTD_LEVEL> -T1"`. The default is 1. The plan
   measured a 397,342,720-byte tar of a box's `state/` at `-T1`: level 3 gave
   65,353,259 bytes in 1.535 s user CPU, level 1 gave 75,999,469 bytes in
   1.009 s. Level 1 uses 34% less CPU for a 16% bigger object. A level outside
   1-19 is logged and 1 is used.
3. **Skip unchanged inputs.** Before the tar, the lane hashes the name, size and
   mtime of every input file (never content) into one sha256, the manifest.
   `state/backup-last.json` keeps the manifest and the `shipped` time of the
   last upload. A run ships nothing when the manifest matches, `shipped` is less
   than `BACKUP_FORCE_HOURS` (24) ago, and a `head-object` of the last key
   returns the recorded size. That run moves only `ts` in the stamp and logs
   `skip: inputs unchanged since <shipped> (<key>) - shipped nothing`. If the
   head-object fails or the size differs, the run logs `skip refused` and
   ships. A stamp with no `manifest` (written before this change) ships.
4. **Not inputs.** The manifest leaves out the lane's own outputs (its log, its
   stamp, the unconfigured markers), `state/scratch/`, and the TTL caches every
   lane gate rewrites on each run (`state/lane-gate/`,
   `state/settings-cache.json`, `state/flags-cache/`). This lane's own gate
   rewrites them before the manifest, so with them counted no run could match.
   They still go into the tar.
5. **Back up now.** `bin/box-ops.sh` `backup_now` runs the lane with
   `BACKUP_FORCE=1`, so the console action always uploads and its
   `uploaded <key>` line names a new object.

## Knobs

All in `catalog/lanes.d/state-backup.json`: `BACKUP_ZSTD_LEVEL` (1),
`BACKUP_SKIP_UNCHANGED` (1; 0 ships every run), `BACKUP_FORCE_HOURS` (24), and
`BACKUP_FORCE` (0, not settable from the control plane).

## Limits

- On the hub, `logs/` and `state/` change every minute, so the skip almost
  never fires there. The hub saving comes from items 1 and 2. On the other
  boxes, every lane that writes to `logs/` between two runs also makes the
  next run ship.
- A file rewritten at the same size inside the same mtime tick, or restored
  with `cp -p`, does not change the manifest. `BACKUP_FORCE_HOURS` bounds that
  miss to 24 hours.
- Ask 4 of the ticket (move the backup off the hub) is not built. The
  per-project lanes of #6047 now run on Fly machines, and those cannot read the
  hub's local disk.
- The hub CPU measurement after the deploy is an operator step and is still
  owed.
