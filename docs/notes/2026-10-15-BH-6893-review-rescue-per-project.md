# review-rescue runs per project (BH-6893, BH-6881.11)

Doc: PROJECT-LANES

## What changed

- `bin/review-rescue.sh` has three run modes. The argv decides the mode:

  | argv | mode |
  |---|---|
  | (none) | fleet run: every project's records in one process, as before |
  | `--project <p>`, `--project=<p>` | project run: `<p>`'s records only |
  | `--dispatch` | dispatch: `pl_dispatch review-rescue <spread> bin/review-rescue.sh --project`, then exit 0 |
  | `--dispatch --project <p>` | rc 2, one stderr line, no run |
  | `--project` with a name not in fleet.conf, empty, or with a `.` start or a character outside `[A-Za-z0-9._-]` | rc 2, one log line, no run |
  | any other argument | the fleet run, plus one log line |

- The mode block is after the lane gate, the kill switch and the PATH export.
  So `lane_gate_or_exit`, `lane_env_apply` and `lane_switch` act before a
  dispatch.
- A project run takes `locks/review-rescue-<p>.lock` (flock, dedupe, not a
  queue). Under `bin/project-lane-run.sh` it uses the runner's lock on
  `PL_LOCK_FD`. A run started by hand takes the same lock with `pl_lock_take`,
  or with `flock -n` when `bin/lib/project-lanes.sh` is not there. If the lock
  is held, the run writes one line and exits 0.
- A project run sets `RESCUE_ONLY=<p>` and `PROJECTS=<p>`, re-arms the
  project's GitHub credential (`pl_token`) and writes `project run <p>` to
  `logs/review-rescue.log`.
- `RESCUE_ONLY` now narrows all three passes:
  - `verdict_backfill` walks `builds/{,pool-,fly-}<p>-*/` only, and skips a
    record whose project (`project-of.sh --prefix`) is not `<p>`.
  - `ledger_materialize` already filtered on `RESCUE_ONLY`. It is unchanged.
  - The candidate walk reads `builds/<p>-*/` and `builds/pool-<p>-*/` only,
    and skips a REVIEW_BLOCKED record whose project (`sd_rec_ids`) is not
    `<p>`. So a `pa` run never takes a `pa-x-…` record.
- With no argument and no `RESCUE_ONLY`, the three passes run as before.
- The dispatcher has no fleet part, because every pass is per project. It
  takes no lock and touches no record.
- If `bin/lib/project-lanes.sh` is not there, `--dispatch` writes one log line
  and does the fleet run.

## Settings and knobs

- `RESCUE_DISPATCH_SPREAD_SECS` (registry knob,
  `catalog/lanes.d/review-rescue.knobs.d/`): default 600 s, 0..1500. Each
  project starts at a stable offset inside this window. A non-number gives one
  log line and 600.
- `lane_placement.review-rescue` (settings row,
  `worker/jobs/schema.d/202610160520-bh-6893-review-rescue-placement.sql`):
  seeded `hub`. No table is created, so no index or retention rule applies.
- `RESCUE_PER_TICK` and `RESCUE_HUMAN_STEP_PER_TICK` count per run. In a
  project run that is per project per tick. To lower the total, set the knob
  row lower. The lane's daily LLM cap (`AGENT_CALL_LANE=review-rescue`) still
  binds the lane total.

## Cron

`cron/lanes/310-review-rescue.cron`:
`7,37 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/review-rescue.sh --dispatch >> /root/harness/logs/review-rescue-cron.log 2>&1`.
The hub-lease gate is unchanged. `pl_dispatch` appends each project run's
output to `logs/review-rescue-cron.log`. The summary line goes to
`logs/review-rescue.log`:
`review-rescue dispatch: started <n> project run(s) (period 600s, no cap), <h> held: […]; placed: <f> fly, <n> hub (<why>)`.

## Manifest inventory

`catalog/lane-run-inputs.d/review-rescue.rw` (what one project run writes),
with `file:line` for each entry in the file:

- The record files under `builds/<p>-<KEY>-*/`, `builds/pool-<p>-<KEY>-*/` and
  `builds/fly-<p>-<KEY>-*/`: RESULT, RESULT.tmp, review.md, plan.md,
  pr-body.md, rescue-lane.log, rescue-review-run.txt, test-tamper-rescan.txt,
  .rescue-attempts, .review-rescued, .verdict-backfilled, .human-step-checked,
  .human-step-none, .human-step-waiting-said, .rescue-materialized,
  .stale-flagged, .conflicts-with-main, .findings-general.
- `state/ticket-stage/<p>.tsv` (`nh_sd_stage_put`).
- `state/blocked-resolver/handoffs/claims/<p>-<KEY>` (`bhw_claim`).

`catalog/lane-run-inputs.d/review-rescue.ro` (read only): pipeline.log,
reviewed-sha, review-head, .blocked-resolver-superseded and
.blocked-resolver-abandoned in the same record dirs;
`state/blocked-resolver/<p>/*.json`; `fleet.conf`; `flags/*`.

`tests/review-rescue-per-project.bh-6893-test.sh` case P3 publishes the
snapshot, fetches it onto an empty root, runs `--project pa` there and checks
that every file the run writes is in `.rw` or on its NOT CARRIED list. CI has no
strace, so the suite does not trace `open()`.

## What blocks a flip to fly

The NOT CARRIED block of `review-rescue.rw` lists them:

- `logs/ALERTS.log`: the alert lines go through `bin/alert-line.sh` on the
  hub. This waits for the alert path off the hub (#6889).
- `$REPOS/<p>`: the rescue fetches, adds a worktree, merges main and pushes
  through `hold_push`. A lane machine has no clone.
- Machine-local files that never ride: `env/*`, `locks/*`, `state/gh-*`,
  `logs/gh-calls/*`, `state/alert-line-sent/*`, `state/alerts/*`,
  `flags/alerted-*`, `logs/cost.csv`, and the `builds/.pool-*.tmp.*` staging
  dirs.

This slice does not flip the lane. The flip is a settings row change after a
proof run.
