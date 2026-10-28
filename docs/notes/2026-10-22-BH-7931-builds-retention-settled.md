# builds/ retention on every box, and rule 2 `settled` (BH-7931)

Doc: OPERATING, HARNESS-COORDINATION

## What changed

- `builds-retention` runs on all 11 fleet boxes (`catalog/lanes.d/builds-retention.json`,
  scope `box`). The hub keeps its hub-lease gate (`# @box hub` + `# @hub-lanes`
  in `cron/lanes/737-builds-retention.cron`). The other boxes run it ungated,
  because each box retains its own disk. The archive is `builds-archive/` on
  each box, as before.
- Rule 2, `settled`, in `bin/builds-retention.sh`. A group with no `PR_MERGED`
  dir moves when it is swept, older than `builds_retention.settled_window_days`
  (30), not live, not remote-json, not a collision, AND one of:
  - superseded: a dir has a `SUPERSEDED` marker, or another group of the same
    project has the same `job.json` `ticket_id` (not `-`) and a newer stamp;
  - all-terminal: every dir has a RESULT that starts `FAILED`,
    `BUILD_DEFERRED`, `CLOSED` or `NEEDS_HUMAN_VERDICT`;
  - closed: the tracker says the ticket is closed.
- New lib `bin/lib/ticket-state.sh` (`tks_state`): one ticket read through the
  tracker contract (`bin/lib/tracker.sh`), `open` or `closed`, rc 1 unreadable,
  rc 75 rate limited. GitHub reads are optional reads (`GH_REST_OPTIONAL=1`), so
  the quota reserve refuses them first. Its test seam is
  `BUILDS_RETENTION_TICKET_STATE_FILE`.
- New kept reasons in the run line: `settled-open`, `settled-young`,
  `tracker-unreadable`, `tracker-budget`. New fields: `settled=<d>` and
  `tracker_reads=<n>`.
- New warn alert `builds-retention:drain`: two real runs in a row (less than
  48 h apart) hit `max_dirs`. A real run that is not capped resolves it.
- Two new settings rows (seed
  `worker/jobs/schema.d/202610272153-bh-7931-builds-retention-settled.sql`):
  `builds_retention.settled_window_days` (30; 0 turns rule 2 off) and
  `builds_retention.tracker_reads_max` (200).
- `builds_retention.dry_run` is not changed. The flip procedure is in
  `docs/HARNESS-COORDINATION.md`.

## Why

The 2026-10-21 fleet survey: the hub's last run saw dirs=10282 groups=4711
eligible_groups=0, kept not-merged=3294 young=1402. Rule 1 only moves merged
groups, so a real run would still move 0. The other boxes (box-small
10,500 dirs, project-5 4,932, project-6-os 4,025, project-4 1,792) did not run the lane.

## Choices

- "Superseded" reads as above. Splitting one key's dirs into separate groups
  would break the BH-7437 rule that a group moves only whole.
- The three OR conditions are read as written: an open ticket whose old group
  is superseded or all-terminal moves. The tracker is read only when neither
  holds.
- The terminal words are a code constant: they name the harness RESULT
  vocabulary, not a business parameter.
- A `SUPERSEDED` or `TERMINAL` custody marker (`bin/fly-pool.sh`
  `pool_custody_sweep`) counts as a close-out for rule 2 only. Rule 1 is
  unchanged.
- The settled cut is `now - (settled_window_days + 1) days`, the same +1 day
  as rule 1.
- `tracker_reads_max` bounds the GitHub cost: the hub's 3,294 unmerged groups
  could cost about 6,600 calls in one run without it. A GitHub read is two
  calls (the issue and its comments).
- A jira or linear project answers `tracker-unreadable` (no lane context for
  them yet). Board statuses `done`, `closed`, `archived`, `cancelled` and
  `canceled` are closed (`bin/lib/lookback-board.sh`).
- "Moves more than max_dirs two days in a row": a run never moves more than
  max_dirs, so the alert fires on two real capped runs in a row.

## Tests

`tests/builds-retention-settled.bh-7931-test.sh`. `tests/builds-retention.bh-7437-test.sh`
pins rule 1 with `settled_window_days=0` in scenario A, and its R18 regex has
the new fields.
