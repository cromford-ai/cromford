# The Fly pool's spawn caps, terminals and holds as rows

Doc: DB-COORDINATION-SPEC, FLY-BUILDER-TRIAL

## What was wrong

`bin/fly-pool.sh` runs on the hub and decided three spends from files that
existed only there, under `state/pool/<p>/`:

| file | what it decides |
|---|---|
| `<KEY>.spawns` | the per-key spawn cap (`pool_spawn_cap_check`) |
| `<KEY>.terminal` | a push-rejected key is not respawned until its head moves or a human re-arms it (`pool_terminal_check`) |
| `_spawn-hold` | a runner-lane failure holds every spawn and reuse for the project (`pool_spawn_held`) |
| `<KEY>.held` | the held count on the fleet page (`bin/fleet-status-push.sh`, `bin/progress-push.sh`) |

A rebuilt or failed-over hub lost all of them. Every capped key then got
`POOL_SPAWN_CAP_PER_KEY` fresh `performance-8x` machines, every terminal key
respawned into the same rejected push, and a lane-failure hold was forgotten.

## What changed

- Three D1 tables (`worker/jobs/schema.sql`, also self-created through
  `CREATED_TABLES` in `worker/jobs/src/lib/core.js`):
  - `pool_spawns(project, ticket_key, ts, box, machine, created_at)`, PK
    `(project, ticket_key, ts, box)`: one row per `.spawns` line.
  - `pool_terminals(project, ticket_key, branch, head_sha, reason, created_at,
    box, cleared_at, cleared_why, updated_at)`: a re-arm sets `cleared_at`
    rather than deleting; a new verdict resets it to NULL.
  - `pool_holds(project, kind, ticket_key, ticket_id, until_at, why, first_seen,
    last_seen, box, updated_at)`: kind `spawn` (`ticket_key=''`, `until_at`
    epoch) or `ticket` (a `.held` marker). A clear deletes the row.
- Routes in `worker/jobs/src/routes/pool-state.js`: `GET /api/pool-state`
  (the whole snapshot, lists capped at 2000/500/500 with a `truncated` flag),
  `POST /api/pool-state/spawns` (at most 500 rows, one batch, `ON CONFLICT DO
  NOTHING`), `POST /api/pool-state/spawns/remove` (one row), `PUT`/`PATCH
  /api/pool-state/terminal`, `PUT`/`PATCH /api/pool-state/holds`, and `PUT
  /api/pool-state/claim-machine`.
- The seam `bin/lib/pool-state-rows.sh`. `bin/fly-pool.sh` writes each file as
  before and then the row, and reads one snapshot per tick right after
  `pool_spawn_cap_load`:
  - the spawn cap counts `max(rows, file)` in the window. A row write that
    failed in an outage leaves the DB short, and the file can only raise the
    count. With no file (a rebuilt hub) the rows alone decide.
  - a terminal row decides when there is one: active, it is the verdict;
    cleared at or after the local file's `created_at`, the file is stale and is
    deleted. A file newer than the clear is a verdict that never reached the
    row, so the file decides and re-sends it. With no row the file decides as
    before and is sent `if_absent`. A head change or a human re-arm clears the
    row as well as deleting the file.
  - a spawn-hold row that is still in force holds every hub. The file still
    holds on its own (a hold set during a tick is in the file before that tick's
    snapshot can show it).
  - the held count on the fleet page and the progress push reads the ticket
    hold rows; `fleet-status-push` keeps its rule that a held key with no queue
    file counts nothing.
- Machine to key: under `build_queue_rows_only`, `spawn_one` stamps the machine
  id onto the `build_queue` claim it won before `fly machine run`
  (`PUT /api/pool-state/claim-machine`, 409 when the claim names another
  machine). `pool_key_live` answers "is this key already building" from the
  claim first and this hub's `state/fly-pool/<p>/<mid>.json` second; it
  replaces the bare grep in the rows materialise loop and the reuse handoff.
- `bin/pool-state.sh` (hub, no cron line): `backfill [--dry-run] [project...]`,
  `lift-hold <p>`, `show <p>`.

## The knob

The settings row `pool_state_rows` (seeded `0`), env `POOL_STATE_ROWS` the
documented fallback, resolved by `_flag_on_row`. Off makes no request and writes
no log line: every reader returns "unknown" and the caller reads its file. The
one exception is the claim stamp, which runs whenever `build_queue_rows_only` is
on, because the claim it stamps only exists on that path.

With the knob on and no answer (an outage, a 404 from an older worker, or a 200
that is not the contract), the tick writes ONE `POOL_STATE_FALLBACK <p>` line to
`logs/fly-pool.log` and every reader uses its file. A cut spawns list logs
`POOL_STATE_TRUNCATED` once and still takes `max(rows, file)`.

Lifting a lane-failure hold early now needs the row lifted as well as the file:
`bin/pool-state.sh lift-hold <p>` does both. The lane-failure alert names it.

## The flip (an operator step, not part of the PR)

In a quiet window, never with a restart-lane merge armed, and only after the
deploy serves the merge sha:

1. `bin/pool-state.sh backfill --dry-run`
2. `bin/pool-state.sh backfill`
3. set `pool_state_rows=1`
4. `bin/pool-state.sh backfill` again (idempotent; it closes the gap between 2 and 3)
5. watch one full pool cycle: `grep -c POOL_STATE_FALLBACK logs/fly-pool.log`
   should be 0, and `bin/pool-state.sh show <p>` should agree with
   `ls state/pool/<p>/`
6. post the before/after on #4951

Rollback is `pool_state_rows=0`. The files were written the whole time.

## Known edges

- Two spawns of one key in the same second on one hub collapse to one row
  (the primary key). The queue claim makes that impossible for one key, and
  `max(rows, file)` still counts the file.
- A backfill keys the k-th repeat of one ts in one file as `<box>#k`, so a line
  this hub already recorded live collides with its row and is not counted twice.
- Window maths uses this box's clock, as the file did.
- `RB-*` (rebase) keys are still never recorded.

## Follow-ups

- A `pool_state_rows` row in the console's STATE PATHS panel (#5000, PR #5051).
- Wave 6 of #4951 removes the file writes once the rows have run a full cycle.
- `.hold-noted`, `.pr-noted` and `.defer-to-human` stay files: they are
  once-sentinels for comments and pages, not spend decisions.
