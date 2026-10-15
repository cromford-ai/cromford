# Lane runs: one batch enqueue per tick (BH-6886, BH-6881.8)

Doc: PROJECT-LANES

## What changed

For a lane placed `fly`, `pl_dispatch` (bin/lib/project-lanes.sh) no longer
sends one `POST /api/lane-runs` per project. The loop collects the eligible
projects. After the loop, `lp_enqueue_batch` (bin/lib/lane-placement.sh) sends
them to the new route `POST /api/lane-runs/batch`, one call per 500 projects.
It builds every payload with one `jq` call and reads every answer with one more.

The hub branch does not change. The hub-start lines moved into
`_pl_start_one`, without a change, so the loop and the failed-batch path share
them.

## The route

`POST /api/lane-runs/batch {lane, box?, rows: [{project, args}]}` takes 1..500
rows (worker/jobs/src/routes/lane-runs-batch.js). It validates every row first,
with the same args rules as `POST /api/lane-runs`. A bad row, a duplicate
project, 0 rows or 501 rows is a 400 that writes nothing. Then ONE statement
runs: `INSERT … SELECT … FROM json_each(?4) … ON CONFLICT (lane, project) WHERE
status IN ('queued','claimed') DO NOTHING RETURNING id, project`. The conflict
target is the existing partial unique index `lane_runs_live`. The answer is
200 `{lane, as_of, enqueued, already_live, rows}`, with each row in input
order as `enqueued` with its id, or `already_live`.

No new table and no new index. `EXPLAIN QUERY PLAN` on 20,500 seeded rows
shows one step, `SCAN j VIRTUAL TABLE INDEX 1:` (the input array), and no scan
of `lane_runs` (tests/lib/lane-runs-batch.bh-6886.mjs, R6).

## How an answer counts

- A row named `enqueued` with an integer id: `fly`.
- A row named `already_live`: `already live`.
- Every other project (a 500, a transport failure, a 2xx that does not parse,
  or a 2xx that leaves the project out or gives another status): it runs on
  the hub, counts as `enqueue failed -> hub`, and the dispatch writes ONE
  `lane-placement:<lane>` alert, as before.
- A 404 means the worker has no batch route yet. No more batches are sent, and
  the projects not yet placed take the per-row `lp_enqueue` path, as before
  this ticket. So the hub and the worker can deploy in either order.

The summary line format does not change.

## The numbers

Measured by tests/hub-load-budget.bh-6886-test.sh on this build (a stub jobs
client and a counting PATH shim; "forks" are the external commands the shim
sees):

| fleet | HTTP calls | forks |
|---|---|---|
| 10 projects | 1 | 8 |
| 500 projects | 1 | 8 |
| 1000 projects | 2 | 8 |

Forks per tick at 13 projects: per-row path 34, batch path 8. The per-row
number is the 404 fallback path in the same stub. The stub has no
`_jobs_box_name`, so a real per-row tick forks more than that.
