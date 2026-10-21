# BH-7432: the pool tick wrapper enqueues every fly-placed project in one batch call

Date: 2026-10-21. Refs #7432. Builds on BH-7505 (#7515: one lane_runs row per
project, `bin/fly-pool-project.sh` under the project lease) and BH-6886
(`lp_enqueue_batch`, `POST /api/lane-runs/batch`).

## What changed

Before, `bin/fly-pool-tick.sh` started `bin/fly-pool.sh <p>` for every project.
For a project placed fly, that start then enqueued its own row (`pp_gate` ->
`_pp_enqueue` -> `lp_enqueue`, one `POST /api/lane-runs` per project). The hub
paid a full `bin/fly-pool.sh` start per project per tick for a project it did
no work for.

Now the wrapper calls `ptb_split` (`bin/lib/pool-tick-batch.sh`) before
`tick_start_capped`. `ptb_split` classifies each project, sends ONE
`POST /api/lane-runs/batch` per 500 projects, and sets `PTB_HUB` to the
projects that still need a hub tick. Only `PTB_HUB` is started. The
`POOL_AUTOSCALE=0` sequential sweep is not changed.

## The decision rule

`ptb_split` does nothing (every project is started, no call, no log line) when
any of these is true:

- `POOL_TICK_BATCH` is 0.
- `pp_none_fly` says no `lane_placement.fly-pool*` row is fly or `box:` and
  no project has a placed mark (a fresh settings cache).
- The jobs client is not loaded.
- The lane's `lane_placement.fly-pool.hub_only` text is set (read once per
  tick; `lp_decide` makes every project hub then).

Per project, in input order:

| input | class |
|---|---|
| its lock is held (`tick_held`) | hub (its own lock turns the start away) |
| placement hub, not known, the default row only, `flyy`, a rollback mark | hub (`pp_gate` decides) |
| placed fly or `box:<name>`, newest row queued (inside the stale window) or claimed | skip, one `(batch)` line |
| placed, no row / done rc 0 with a PROF line / withdrawn, no backoff | publish, then the batch |
| placed, newest row stale, box-silent, failed, deferred, a read failure | hub (`pp_gate` takes it back) |
| placed, a take-back inside `POOL_FLY_TAKEBACK_BACKOFF_S`, fallback hub | hub (`pp_gate` runs the backoff) |
| in the batch, the answer leaves it out (404, 500, a partial answer) | hub (`pp_gate` sends its own row) |

A project is "handled" only when the batch answer names it `enqueued` (with an
id) or `already_live`. The `(batch)` lines and the summary counts come from the
answer, never from the sent list. `ptb_split` never takes a lease, never
withdraws a row and never runs a fallback. Those stay in `pp_gate`.

Log lines (`logs/fly-pool.log`):

- `[pool/<p>] placed fly: enqueued fly-pool <p> (batch) — no hub pool work this tick`
- `[pool/<p>] placed fly: a row of <p> is already live (batch) — ...`
- `[pool/<p>] placed fly: row <id> is queued — no hub pool work this tick (batch)`
- `[pool] batch: <e> enqueued, <l> live, <s> skipped live, <h> to hub (<n> batch call(s))`

`placed box:<name>` replaces `placed fly` for a box placement.

A batch row has args `["bin/fly-pool-project.sh"]`. `bin/project-lane-run.sh`
appends the row's project, so the machine runs `bin/fly-pool-project.sh <p>`,
the same command as a per-row enqueue.

## The knob and the rollback

- `POOL_TICK_BATCH` (lane `fly-pool-tick`, settings row
  `lane.fly-pool-tick.pool_tick_batch`, default 1). 0 = start every project,
  as before this change.
- `lane_placement.fly-pool.hub_only` (any text) keeps every project on the hub.
- `lane_placement.fly-pool.<p>=hub` moves one project back. `pp_gate` runs its
  rollback (withdraw, lease, mark removal) on the next start.

In production no `lane_placement.fly-pool.*` row says fly today, so
`pp_none_fly` answers rc 0 and the path makes no call until an operator sets
the first row.

## Measured counts

`tests/fly-pool-tick-batch.bh-7432-test.sh` prints them. One wrapper tick on a
scratch hub root, 13 projects placed fly, no rows yet, real jobs worker on
node:sqlite. "Forks" are the external starts a PATH shim counts.

BEFORE (main bdf7a8d4, the same suite, red run):

- snapshot publish throttled: 1175 forks, 74 HTTP calls, 13 `POST /api/lane-runs`, 0 batch POSTs, 13 `bin/fly-pool.sh` starts
- every publish due: 2278 forks, 127 HTTP calls, 13 single POSTs

AFTER (this change):

- snapshot publish throttled: 281 forks, 30 HTTP calls, 0 single POSTs, 1 batch POST, 0 `bin/fly-pool.sh` starts
- every row live (the second tick): 152 forks, 0 POSTs
- every publish due: 1346 forks, 82 HTTP calls, 1 batch POST (the 13 `lri_publish` runs are BH-7505's cost, unchanged; ASSUMPTION A2 of the plan)
- the wrapper with no project at all: 37 forks (its fixed cost)

To reach the 300 bound, `pp_publish` and `_pp_int` in
`bin/lib/pool-placement.sh` read the clock, the stamp file and the knob with
bash builtins instead of `date`, `head` and `tr` (the same values). This also
cuts 3 forks per project from the per-row `pp_gate` path.

The ticket metric (hub CPU per project tick over 24 h of #6882 samples after
the flip) needs the flip of a live placement row. It is an operator step after
merge.
