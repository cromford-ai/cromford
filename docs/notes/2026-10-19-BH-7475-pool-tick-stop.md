# A pool tick stops at a row boundary on a code change or a max age (BH-7475)

Doc: FLY-POOL

## Why

`bin/fly-pool.sh <project>` holds `locks/fly-pool-<p>.lock` for its whole
process life. On 2026-10-19 a project-6-os tick started on old code at 01:53Z
and held the lock for 5.5 h. The #7435 fix synced to the hub at 07:25Z, but
every new tick logged "already running" and exited. An operator sent SIGTERM
at 07:30Z.

## What changed

`bin/lib/pool-tick-stop.sh` (`pts_init`, `pts_code_fp`, `pts_stop_due`).
The tick calls `pts_init` right after it takes the lock. It calls
`pts_stop_due` at each row of the REAP walk (tracked machines) and of the
SPAWN walk (queued rows). Two rules stop the tick:

1. **Code change.** The tick takes a stat fingerprint (name, inode, size,
   mtime) of its own script and of every `lib/<name>.sh` the script names, at
   start and at each row. rsync and `lrc_sync` replace a file by rename, so a
   deploy that changes pool code changes the fingerprint. A merge that does
   not touch these files does not stop the tick. The tick writes one log line:
   `tick stopped at a row boundary: the deployed pool code changed since the tick started (fp <old> -> <new>)`.
   There is no alert and no knob. A lib that only another lib sources is not
   in the fingerprint; the max age covers it.
2. **Max age.** `POOL_TICK_MAX_AGE_S`, settings row
   `lane.fly-pool.pool_tick_max_age_s`, code default 1200, 0 = off. The age
   counts from the lock. The tick writes one log line
   (`tick stopped at a row boundary: it has run <n>s, past POOL_TICK_MAX_AGE_S=<max>s`)
   and ONE ALERTS line per tick, id `pool-tick-max-age-<p>`:
   `[pool/<p>] tick ran <n>s, past POOL_TICK_MAX_AGE_S=<max>s: it stopped at a row boundary and released the lock`.
   If both rules are true, the tick reports the max age.

A stop in the REAP walk waits for started work and exits rc 0. Unvisited
machines keep their `state/fly-pool/<p>/*.json` files. The dead-machine sweep
and the spawn walk run on the next tick. A stop in the SPAWN walk runs the
walk's normal tail: started spawns finish (`wait`), then `exit 0`. Unvisited
rows stay in `state/build-queue/<p>/`. In both cases the EXIT traps run and the
lock is free.

`POOL_TICK_BUDGET_S` (BH-7421) is not changed. It still times the spawn walk
only, from the start of that walk.

## What an operator sees

- The max age equals `POOL_TICK_HARD_LIMIT_S` (1200 s) in
  `bin/fly-pool-tick.sh`. A tick that reaches a row boundary now stops on its
  own at that age. So the wrapper's "tick has run Ns … NOT killed" alert now
  means one thing: the tick is stuck INSIDE one row (one hung call).
- A `pool-tick-max-age-<p>` alert means a tick was slow over many rows. Read
  `logs/fly-pool.log` for that project to find the slow rows.
- To check a deploy: `grep 'tick stopped at a row boundary' logs/fly-pool.log`
  after a deploy that changes `bin/fly-pool.sh` or a lib it names.

## Test

`tests/fly-pool-tick-stop.bh-7475-test.sh`: cases A, B, C, D, E, F, R drive
`bin/fly-pool.sh` with a real lock; U1-U6 drive `pts_stop_due` on its own.
