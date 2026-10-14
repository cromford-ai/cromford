# Archie's second playbook: the data lane (BH-4927, BH-4920.4)

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

## What changed

The archie-fm `*/10` tick (`bin/archie-fm.sh`) now hands every open PR that
its restack classifier leaves unclassified to a second playbook, `data-lane`
(`dl_one_pr` in the wrapper; `afm_classify_data_lane` and `afm_dl_act` in
`bin/lib/archie-fm.sh`). No cron line and no state file were added.

A PR is a candidate when all of these hold:

- the conductor row is not MERGED, CLOSED or ABANDONED;
- `mc_record_for <url>` finds its build record;
- that record's `review.md` carries a `DATA_LANE:` line, and
  `dl_reviewed_sha` equals the PR head;
- `dl_candidate` (`bin/lib/data-lane.sh`) is rc 0 against the PR's real file
  list (`GET repos/<slug>/pulls/<n>/files`, one page of 100; a path missing
  from a full page is no candidate).

The PR is then skipped, with no row, if its head is a fork, its branch is not
a harness build branch, it is on HOLD, the data-lane lane is paused
(`lane_paused data-lane`: `all-off`, `lane-off-data-lane` or their rows), or
(mode on) fewer than `AFM_DL_BOUND_S` (360) +
`AFM_TICK_SLACK_S` seconds are left in the tick. The conductor's PR lock and a
resolver hand-off are not skips: the lane pushes nothing, and every BLOCKed PR
is the resolver's.

Otherwise it claims the `archie_actions` row
`data-lane:<project>:<pr>:<head12>` (`:observe` appended in observe mode)
BEFORE anything runs. The day cap is the settings row `archie.cap.data-lane`
(fallback 20, counted over data-lane rows only). Observe closes the row
`would` / `would_apply` and calls nothing. On runs
`bin/data-lane-apply.sh <project> <pr> <build-dir>` once, under `timeout`, and
closes the row:

| apply rc | word | row |
|---|---|---|
| 0 | `applied` / `already-applied` | `done` / `apply` |
| 0 | anything else (lane off) | `deferred` |
| 1, 2 | | `failed` / `apply` (the script already alerted) |
| 75, 124, 137 | | `deferred` (the stale-row ladder retries it, then one alert) |
| 3 | | `skipped` / `not_candidate` |
| 5 | | `skipped` / `no_path` |
| other | | `failed` |

The jobs worker route accepts the new playbook, actions and the terminal
outcome `skipped`. `GET /api/archie/actions?summary=1` gains
`data_lane {total, applied, escalated, would}` (escalated = failed rows plus
`skipped`/`no_path`). The daily digest prints
`Factory manager, data lane: applied N migrations ahead of merge, M escalated`
under the Factory manager line when that total is above 0.

## Why

BH-4920 lets a PR whose only BLOCK is its unapplied migration have that
migration applied ahead of merge. BH-4923 shipped the contract and the apply
script with no caller; this is the caller.

## Choices a reader may trip on

- The observe key carries `:observe` because the worker treats the same key
  with a different mode as a 409. One shared key would strand every head
  observed before a project flips to `on`.
- rc 5 (`no_path`) is terminal for that head. Configuring the endpoint later
  does not re-run Archie on an already-skipped head; a new head does.
- The tick log gets one extra line, `data_lane candidates=… applied=… would=…
  deferred=… skipped=… escalated=… failed=…`. The restack summary line is
  unchanged.

## How to see it

`grep data_lane /root/harness/logs/archie-fm.log | tail -1` on the hub, and
`GET /api/archie/actions?day=<today>&summary=1 | jq .data_lane` on the jobs
worker. Suites: `tests/archie-fm-data-lane.bh-4927-test.sh`,
`worker/jobs/test/archie-actions-data-lane.bh-4927.test.js`.
