# The harness sync heals a failed fast-forward, and the pool pages when it is under-used (BH-7382)

Doc: FLY-BUILDER-TRIAL, OPERATOR-SETUP

## Why

On 2026-10-18 the project-6-os pool ran 5 builds while 22 tickets waited.
Alert 30563 showed the box's harness sync stopped at `pull-failed, rc 20`, so
the context gate refused every build on the box. The sync wrote no git stderr
on stdout or in an alert, so nothing said why the pull failed.

## What changed

1. **Harness sync fast-forward** (`bin/harness-sync.sh`, deploy mode).
   - The step runs `git merge --ff-only origin/main`, not `git pull`.
     `freshness()` has just fetched that ref under `harness-fetch.lock`, so
     the step makes no second, unlocked fetch.
   - If the merge fails, no tracked file has a change, and HEAD is an
     ancestor of origin/main, the step resets to origin/main. Untracked files
     that origin/main tracks move first to
     `state/harness-sync-displaced/<stamp>/`, and the step keeps the 5 newest
     dirs. The log line is `ff failed (<stderr>) — reset to origin/main on a
     clean tree`. The step never deletes a `.git` lock file.
   - Otherwise stdout is `pull-failed: <git stderr, 300 chars>` and the exit
     code stays 20. The `state/harness-sync-last-refused` stamp stays
     `pull-failed`. One ALERTS line per hour carries the stderr and the
     modified tracked files (flag `alerted-harness-sync-ff-h<HH>-<YYYYmmdd>`).
2. **Under-use alert** (`bin/lib/pool-underuse.sh`, called from
   `bin/fly-pool.sh` after `pool_stall_tick`). It fires when queued >
   `POOL_UNDERUSE_QUEUE_MIN` (5) and building < `POOL_UNDERUSE_PCT` (50) % of
   capacity for `POOL_UNDERUSE_ALERT_S` (900 s). Capacity is the pool cap, or
   building + queued when there is no cap. Building is the job files whose
   machine is `started` in the tick's listing. An unusable listing is never
   an alert. The first under-used tick is kept in
   `state/pool-underuse/<p>.json`. Each under-used tick writes one
   `under-used for` line, and one ALERTS line per project per hour
   (flag `alerted-pool-underuse-<p>-h<HH>-<YYYYmmdd>`). The tick does not
   evaluate it when it exits earlier (`POOL_SPAWN=0`, a spawn hold).
3. **Claimed rows with no owner** (`bin/lib/pool-orphan-rows.sh`, called
   from the dead-machine sweep in `bin/fly-pool.sh`, after the REAP). Before
   this change, only `bin/jobs-watchdog.sh` released a `claimed` fly row whose
   job file was gone, at `JOBS_QUEUE_CLAIM_MIN` (360 min). The project-6-os
   wait was 314 min. Now the pool tick releases the row (`queue_release`: row
   back to `queued`, claimant cleared) when ALL of these are true:
   - the tick has a usable Fly listing;
   - this hub claimed the row (`claimed_by` = `JOBS_BOX`) and the target is
     `fly`;
   - the claim is older than `POOL_ORPHAN_ROW_RELEASE_S` (900 s, 0 = off);
   - no `state/build-queue/<p>/<KEY>.json`, no `state/fly-pool/<p>/*.json`
     and no `state/fly/<p>-active.json` names the key;
   - the row names no machine, or the listing has the machine absent,
     `stopped`, `destroyed`, `failed` or `suspended`;
   - the key is not `RB-*` (the watchdog keeps those).

   One tick releases at most `POOL_ORPHAN_ROW_RELEASE_MAX` (20) rows. Each
   release writes one line in `logs/fly-pool.log`:
   `orphan-row-release <KEY>: claimed by <box> <age>s ago on machine <mid|none>
   (<state>), no hub owner — row back to queued`. The line is written only
   after the PATCH returned 0. A tick that released rows writes one ALERTS
   line that names the keys. Live probe after deploy:
   `grep 'orphan-row-release' logs/fly-pool.log` on the hub.

## Not changed

- **Orphan job release.** A tick with a usable listing already releases a job
  whose machine is absent or `stopped` in the same tick: the reap's dead path
  destroys the machine, removes the job file and requeues the key.
  `tests/fly-pool-orphan-capacity.bh-7382-test.sh` pins the ticket's case
  (8 orphans, 6 machines, cap 8: all 8 released, `running=6 spawning=2`).
  Job files outlive the reap when the tick never reaches it, for example
  with no Fly token (BH-7107). In prod, project-6-os reported 8
  `orphan_jobs` in `.sweep.json`, which the sweep counts after the REAP. So in
  prod some REAP path did not close those 8 files. This change did not find
  that path: this box has no hub logs. The claimed-row release does not cover
  that state, because it never touches a row that a pool job file names.
- **Hotfix first slot.** `hotfix_first` already gives a free slot to a hotfix
  (#368). `tests/fly-pool-hotfix-first-slot.bh-7382-test.sh` pins it.
