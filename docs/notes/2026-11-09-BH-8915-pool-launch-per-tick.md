# BH-8915 — Fly pool: limit machine launches per tick across projects

Doc: FLY-POOL

## Problem

On 2026-10-29 a re-put backlog made the pool start 60-75 machines in one tick.
Fly's machines API rate limit refused 62% and then 92% of the project-6-os
launches. The failed jobs went back to the queue, and the next tick hit the
limit again. A temporary pool cap of 16 stopped it by hand.

## Change

- Knob `POOL_LAUNCH_PER_TICK`, settings row `lane.fly-pool.pool_launch_per_tick`
  (`catalog/lanes.d/fly-pool.knobs.d/POOL_LAUNCH_PER_TICK.json`). Default 20.
  0 = no limit. A value outside 0-1000 uses 20 and writes one line.
- `bin/lib/pool-launch-limit.sh` (`pll_limit`, `pll_take`, `pll_spent`,
  `pll_used`, `pll_held_line`). A launch slot is `mkdir "$POOL_LAUNCH_TICK_DIR/<n>"`,
  n = 1..limit. mkdir is atomic, so parallel project ticks never take more
  than the limit. No tick dir: the count is per process. A tick dir that is
  set but gone refuses every slot for the rest of that tick.
- `bin/fly-pool-tick.sh` makes one tick dir per run,
  `state/fly-pool-launch/<UTC stamp>.<pid>/`, and exports it as
  `POOL_LAUNCH_TICK_DIR` to every project tick it starts (autoscale start and
  sequential sweep). It deletes tick dirs older than `POOL_TICK_HARD_LIMIT_S`
  first. If the mkdir fails, it writes one `[pool] launch limit: no tick dir`
  line and each project tick counts alone.
- `config/fly-pool.d/3900-spawn-loop.sh` (rendered into `bin/fly-pool.sh`):
  - The walk checks the limit after the local filters (failed park,
    quarantine, already in the pool, duplicate key, dispatch-mode hold) and
    before the RB branch and the spawn decision. A held row gets no decision
    and no GitHub read, and stays queued. With verdicts pending, the walk
    first waits for them, because a pending row can take the last slot.
  - `pool_walk_spawn` takes a slot first. A row whose decision started before
    another project took the last slot is held there. Nothing is claimed.
  - After the walk, one line when a row was held:
    `launch limit: held <n> launch(es) past pool_launch_per_tick=<L> (<used> of <L> used this tick across projects) — they wait for the next tick`.
    The `decided ...` line names `launch-limit` as the stop.
- Hotfix rows walk first (`hotfix_first`, unchanged), so they take the slots
  first inside each project's walk.
- The limit does not cap running machines. The pool cap logic is unchanged.
  Machine reuse (a queued job handed to a live machine) is not a launch.

## Limits

- The shared count is per wrapper run on one host. A project tick on a Fly
  lane-run machine or another box has no `POOL_LAUNCH_TICK_DIR` and counts its
  own launches against the same limit.
- A slot is spent when `spawn_one` starts, even if it then fails before
  `fly machine run`.
- A project tick that outlives its wrapper run keeps its old tick dir, so for
  one window two wrapper runs can each spend the limit.

## Tests

`tests/fly-pool-launch-per-tick.bh-8915-test.sh`. `tests/pool-autoscale-test.sh`
runs its 40-in-one-tick case with `POOL_LAUNCH_PER_TICK=0`.
