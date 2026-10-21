# Placement `box:<name>`: one project's conductor or pool tick on a named box (BH-7636)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

Pattern: BH-6890 (conductor per project on Fly) and BH-7505 (pool tick on
Fly). The first user is project-6-os on box-project-6-os-1.

## The value

`lane_placement.<lane>.<project>` = `fly` | `hub` | `box:<name>`.

- `box:<name>` is valid only on a PROJECT row of lane `merge-conductor` or
  `fly-pool`. On the lane row, on `lane_placement.default`, or for any other
  lane it reads `hub`, and `LP_WHY` says `box: only on a project row of
  merge-conductor or fly-pool`.
- Parse rule (one rule, two readers): delete every whitespace character,
  lowercase A-Z, then match `^box:[a-z0-9][a-z0-9._-]{0,63}$`. The shell reader
  is `lp_box_parse` (`bin/lib/lane-placement.sh`). The worker reader is
  `parseBoxValue` (`worker/jobs/src/lib/lane-box-placement.js`).
  `tests/fixtures/bh-7636/box-placement-cases.tsv` is read by the tests of both.
- A non-empty `lane_placement.<lane>.hub_only` row keeps the lane on the hub,
  as for `fly`.

## What each side runs

| side | what it does |
|---|---|
| hub | Its normal tick of the project reaches the gate (`mc_proj_gate` for the conductor, `pp_gate` for the pool). The gate applies the pending write-backs, publishes the snapshot, and enqueues ONE `lane_runs` row. It runs no PR work and no pool work for the project. Log tag: `<project> project-box(<name>): ...` (conductor), `[pool/<project>] placed box:<name>: ...` (pool). |
| jobs worker | `POST /api/lane-runs/claim` with `box: <name>` takes only the rows whose `(lane, project)` is placed on `<name>`. A claim without `box` (every Fly machine) never takes such a row, at any age, and never ends one through the `skip_prefixes` refusal. The stats routes do not count a box row, so a box row never starts a Fly machine. |
| box | Its cron line `cron/lanes/698-lane-run-box.cron` (registry lane `lane-run-box`, boxes `[project-6-os]`) runs `bin/lane-run-box.sh --once --box "$(hostname)"` every minute under `flock -n`; that script gates on `lane-off-lane-run-box` and execs `bin/lane-run-worker.sh` with the same arguments. It claims the row, runs `bin/merge-conductor-project.sh` / `bin/fly-pool-project.sh` under the project lease, posts the write-back, and reports. With no row placed on it, the claim answers 204 and nothing runs. |

State hand-off is the Fly path's: the snapshot through the jobs worker before
the run, and the compare-and-set write-back after it. The project lease
(`project_leases`, BH-6883) keeps one run at a time across hub and box.

A claim answer from a jobs worker older than this change has no `box` field. A
box worker releases such a row at once, does not run it, and exits 1. So a box
that gets the new script before the worker deploy never runs a Fly row.

## The box goes silent

The hub gate uses its existing stale bound (`MC_FLY_QUEUE_STALE_S`, 600 s, for
the conductor; `POOL_FLY_QUEUE_STALE_S`, 300 s, for the pool):

- a queued row that waited the bound or more, or
- a claimed row whose lease ran out the bound or more ago (the box died
  mid-run; `GET /api/lane-runs/by-prefix` rows carry `lease_until`).

The hub withdraws the row (`POST /api/lane-runs/<id>/withdraw`, with
`expired: 1` for the claimed case) and, only after a 200, takes the project
back. The first take-back of an outage writes ONE ALERTS line
(`--id mc-project-box-<project>` or `--id pool-box-<project>`) and the mark
`<project>.box-down`. No other line until the box answers again: a live
claimed row, or a row with a run result (done, deferred, failed with an rc),
removes the mark. A `died` row is no answer. For a box placement the BH-7462
no-capacity streak alert does not fire. After the backoff
(`mc_project_fly.nocap_backoff_s`, `POOL_FLY_TAKEBACK_BACKOFF_S`) the hub
offers the box a new row.

With `lane_fallback.<lane>.<project>` = `off` the hub does not take the project
back. The existing hourly fallback-off alert fires instead of the box-down line.

## Flip and undo

One settings row each, per lane:

- Flip: `lane_placement.merge-conductor.project-6-os` = `box:box-project-6-os-1`
  (and, for the pool, `lane_placement.fly-pool.project-6-os` =
  `box:box-project-6-os-1`).
- Undo: set the same row to `hub`. The hub's next gate removes the `.placed` and
  `.box-down` marks and runs today's tick. A row still queued at the undo is an
  ordinary row again: the box no longer claims it, a Fly machine may, and the
  project lease keeps that run apart from the hub's tick (as for a fly to hub
  undo). The pool gate withdraws such a row on its rollback.

This change does not flip a row. Flip only after the merge is deployed to the
jobs worker AND the box has the cron line (fleet-propagate).

Before the pool flip, the box needs what the pool tick reads on the hub: the Fly
API token for the project's app (`env/fly.env`, `FLY_API_TOKEN_project-6_OS`)
and a GitHub token. The conductor needs the box's GitHub credentials, which
box-project-6-os-1 already has for project-6-os.

## Live proof

1. Write the flip row.
2. Within one hub tick, `logs/merge-conductor.log` on the hub shows
   `project-6-os project-box(box-project-6-os-1): enqueued merge-conductor project-6-os`.
3. On the box, `logs/lane-run-worker.log` shows
   `box-project-6-os-1: run <id> merge-conductor/project-6-os rc 0: reported`.
4. `GET /api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=project-6-os`
   shows that row `done` with `claimed_by` = `box-project-6-os-1` and a
   `PROF mc-project state=MERGED` (or `QUEUED`) line, and the project-6-os PR is
   merged.

## Tests

- `tests/lane-placement-box.bh-7636-test.sh`: the parse table through `lp_decide`.
- `tests/merge-conductor-box.bh-7636-test.sh`: the conductor gate (box-silent,
  one alert per outage, undo), the snapshot backstop, and the real worker:
  hub gate enqueues, a Fly worker claims nothing, the box worker runs and
  reports; the old-worker guard.
- `tests/fly-pool-box.bh-7636-test.sh`: the pool gate.
- `worker/jobs/test/lane-runs-box.bh-7636.test.js`: the claim filter, the
  withdraw `expired`, by-prefix `lease_until`, the stats, and EXPLAIN on 20,000
  rows.
