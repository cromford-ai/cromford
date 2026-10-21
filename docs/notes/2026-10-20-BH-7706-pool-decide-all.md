# The pool tick decides its queued rows in parallel and reads the shared inputs once (BH-7706)

Doc: FLY-POOL

## Problem

On 2026-10-20 a project-6-os pool tick on the hub had 126 queued rows. It
decided 26 of them before `POOL_TICK_BUDGET_S` (600 s) stopped the walk, and
it spawned 7. The spawns were already in the background (`spawn_one ... &`).
The serial part was the decision: `pool_spawn_decision` ran once per row in
the tick's shell, and a row that reached the HOLD gate read its whole issue
thread (30-45 s on the loaded hub). Some reads were the same for every row and
ran once per row: `bin/sibling-serial.sh check` read the parts map, the active
key and the job_claims rows again for each sibling part, and
`pool_after_open` read the jobs queue once per `after` blocker.

## What changed

1. `bin/lib/pool-decide.sh` (new). Before the walk, `pdc_prime` makes the
   shared reads once, in the tick's shell: the spawn-gates probe (and its
   "spawn gates inactive" line, said once), the ai-build issue listing of the
   hold cache, the scheduler ready set, one `queued` and one `claimed` jobs
   queue listing when a row has an `after` blocker, and the sibling-serial
   tick cache. One log line: `decide prime: queue=<n> rows,
   after-blockers=<n>, queue-list=<ok|off(why)>, sibling-cache=<ok|off>,
   parallel=<n>`.
2. The row walk in `bin/fly-pool.sh` starts each decision in a background
   worker (`pdc_start`). The worker runs `pool_spawn_decision` unchanged, so
   every gate says the lines it said before, and writes one verdict file. The
   tick's shell collects each verdict (`pdc_collect`) and starts the spawn
   (`pool_walk_spawn`, the same `spawn_one ... &` line) for a row the decision
   let through.
3. Slots. The walk holds a plain or a hotfix slot from the start of a row's
   decision to its verdict. With every budget slot held, the next row first
   waits for the pending verdicts, so the pool cap and the hotfix exemption
   hold as in a serial walk: a skipped row's slot goes to the next row, and a
   hotfix spends the exemption only when the budget is really spent.
4. The first counted row is decided alone, as the serial walk did (BH-7421:
   "the first row is always decided"). Its PR-unreadable state
   (`_POOL_PR_UNREADABLE`) rides back in its verdict file, so the workers after
   it read no more PRs when GitHub did not answer. A hung or slow GitHub then
   costs one row before the budget and the stop rule (BH-7475) can act, never
   `POOL_DECIDE_PARALLEL` rows. The tick budget is checked in the tick's shell
   before each row after the first. When it is spent, no new worker starts, the line `tick budget of
   <n>s spent ...` is said once, and the workers already started finish and
   spawn. A worker that exits with no verdict file is one line (`decide worker
   for <K> wrote no verdict — skipped this tick`); its row stays queued.
5. One new line at the end of the walk: `decided <n> of <q> queued rows in
   <s>s (parallel <p>); spawn started <k>; not reached <m> (<budget|stop|cap>);
   no verdict <v>`. The `hold cache:` line adds the counters of every worker.
6. `pool_after_open` answers a blocker from the primed queue map. A key absent
   from a complete listing is neither queued nor claimed. A listing that
   failed or filled its page (500 rows, the worker's clamp) keeps the per-key
   `queue_status` read. `pool_pr_bulk_prime` fills the PR cache for each
   row's `after` blocker as well as for its key.
7. `bin/sibling-serial.sh prime <project>` and `SIBLING_TICK_DIR` (new). With
   the env naming a writable dir, `prime` writes the parts map, the active key
   and the job_claims rows (with `fc.ok` only when the claims read answered)
   once, and `check` reads them from there. `files_of` keeps each key's list
   and its source in `lists/`. A missing file is the live read. Without the
   env nothing changes.
8. New knob `POOL_DECIDE_PARALLEL` (default 20, 1-64; settings row
   `lane.fly-pool.pool_decide_parallel`). It bounds the decisions that run at
   once, never the spawns. 1 is the serial walk and the rollback.

## Why 20

The ticket's acceptance line asks that 20 eligible rows with a 2 s read take
less than 3 serial reads (6 s). The first row is decided alone (2 s), so the
other 19 must fit in one wave of 2 s: 19 is the smallest bound that does it,
and 20 is the next round number. The plan proposed 8, which gives 1 + 3 waves
(8 s). Only the GitHub-issue projects (project-6-os, project-5, cromford)
read a hold thread per row, so 3 x 20 = 60 concurrent reads at most, under
GitHub's limit of 100 concurrent requests. The bound stays explicit (D21).

## Not changed

`pool_spawn_decision` and every gate in it. The reuse handoff
(`next_job_or_destroy`) keeps its own serial decision. Clear hold verdicts are
still not cached across ticks (BH-6549 keeps only held verdicts).

## Proof after merge (owed)

On the hub, the project-6-os tick time and the rows decided and spawned for
one tick, from the `decided <n> of <q> queued rows` line. Before: 26 of 126
decided, 7 spawned, 600 s budget spent.

## Tests

`tests/fly-pool-decide-all.bh-7706-test.sh` (the whole tick through
`bin/fly-pool.sh`, A1-A10) and `tests/sibling-serial-tick-cache.bh-7706-test.sh`
(S1-S3). `tests/fly-pool-pr-unreadable.bh-7421-test.sh` case D now uses a 1 s
budget instead of 3 s (TEST-CHANGE): with 2 s reads, rows 2 and 3 now start
together at 2 s, inside a 3 s budget. Its assertion (one row decided, then the
stop) is unchanged.
