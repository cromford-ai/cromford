# The scheduler computes the ready set in shadow (BH-6978, BH-6547.2)

Doc: HARNESS-COORDINATION, DB-COORDINATION-SPEC

## What changed

Wave 2 of 4 of #6547. A new hub lane, `bin/scheduler.sh`, computes which open
`ai-build` tickets are ready to build and gives one reason for each ticket that
is not. It compares that answer with what the existing lanes did in the same
window. It dispatches nothing: no code path in the lane reaches
`bin/run-build.sh`, `bin/fly-dispatch.sh`, the ready queue, the pool queue or
`POST /api/jobs`. Wave 3 (#6979) adds dispatch.

- Lane: `bin/scheduler.sh [<project>|--all]`, registry
  `catalog/lanes.d/scheduler.json`, cron `cron/lanes/733-scheduler.cron`
  (`*/5`, behind `bin/hub-lease.sh check`), switch `flags/lane-off-scheduler`.
  The rule and the compare are pure functions in `bin/lib/scheduler.sh`
  (`sched_decide`, `sched_lanes_did`, `sched_compare`).
- Tables (`worker/jobs/schema.d/202610170424-bh-6978-scheduler-shadow.sql`):
  - `sched_ticks (project, at, mode, candidates, ready, not_ready, unknown,
    in_flight, compared, agreed, idle, partial)`, one row per project per
    tick, unique on `(project, at)`.
  - `sched_diffs (project, ticket, scheduler_says ready|not-ready, lanes_did,
    reason, reason_class, at)`, one row per disagreement, unique on
    `(project, ticket, at)`.
- Routes (`worker/jobs/src/routes/scheduler.js`, fragment
  `worker/jobs/test/route-table.d/bh-6978-scheduler.txt`, bearer-gated):
  - `GET /api/scheduler/holds?project=`: `{holds:[{ticket, state, by, at}]}`,
    the latest `ticket_holds` row per ticket.
  - `POST /api/scheduler/diffs {project, at, mode, counts, partial?, diffs}`:
    one batch, every insert `ON CONFLICT DO NOTHING`, so a retried tick writes
    nothing new. 200 `{ok, tick_written, diffs_written}`. 400 on any bad
    field, nothing written.
  - `GET /api/scheduler/agreement?day=YYYY-MM-DD[&project=]`:
    `{ok, day, from, to, projects:[{project, ticks, compared, agreed, idle,
    rate, top:[{reason_class, n}]}]}`. `rate` is agreed/compared to 3 places,
    `null` when nothing was compared. `top` has at most 5 entries.
- Retention (`worker/jobs/src/routes/retention.js`): rules `sched_diffs.age`
  and `sched_ticks.age`, windows `retention.sched_diffs.days` and
  `retention.sched_ticks.days` (30). Shadow comparison rows: deleted, not
  archived. The hourly `bin/d1-retention.sh` lane runs them.
- Daily digest: `bin/daily-digest.sh` merges the agreement as
  `.scheduler_shadow` (a 404 leaves it out with one note), and
  `bin/lib/daily-digest-render.sh` prints one line per project:
  `Scheduler shadow, <project>: <rate>% agree (<agreed> of <compared>
  compared, <idle> idle, <ticks> ticks). Top disagreements: <class> <n>, ...`.

## The rule

Per candidate, in ascending issue number, the first hit wins:

1. A hard edge to an open parent: `parent #<p> open`. A parent whose state
   could not be read: `unknown` with `parent #<p> unreadable` (not compared).
   A merged parent, or a parent issue closed with no open PR, clears the edge.
   Soft edges are ignored.
2. The latest `ticket_holds` row is `hold`: `hold by <login>`.
3. A planned file equals a file another ticket's running build claims
   (`job_claims`): `files claimed by #<m>`. A candidate with no planned list
   is never "claimed".
4. Otherwise ready. Past the first N ready tickets, where N is the first word
   of `bin/free-slots.sh <project>`: `wip cap`. `unlimited` gives no cap.

A ticket with a running build job, or whose newest build PR is not `CLOSED`
in the `pr_state` ledger, is in flight: counted, not judged.

The parent state comes from the conductor's `pr_state` ledger rows (the
`pr_state` view answers 404 today) for the newest build job's PR. With no job
PR or no row, ONE REST read of the PR whose head is `ticket/<pfx>-<p>`. A
closed or missing PR falls to the issue: in the open `ai-build` listing is
open, else ONE REST read of the issue. At most `scheduler.parent_reads_max`
(20) such reads per tick; past it the parent is unknown. A branch is never
read, so a parent whose branch is kept after its PR merged does not block
(the #6537 case).

## The compare

What the lanes did in the window `(state/scheduler/<p>.last, AT]` (or the
last 300 s): a triage `decisions` row (action `build`, `launch`, `relaunch`,
`rebuild`, `queue`, `enqueue` or `dispatch` is dispatched, any other action is
a hold with the row's reason), a build job created in the window
(dispatched), a `SIBLING_SERIAL <KEY> waits for` line in `logs/fly-pool.log`
or a `HELD:` line from `bin/overlap-schedule.sh` (sibling-serial or
overlap-schedule), a `waiting` `stack-wait` ledger row (stacked-wait).

| scheduler | lanes | verdict |
|---|---|---|
| ready | dispatched | agree |
| ready | held | disagree: one diff row, class `lanes-held:<first lane>` |
| ready | nothing | idle, not compared |
| not ready | held or nothing | agree |
| not ready | dispatched | disagree: one diff row, class `parent-open`, `hold`, `files-claimed` or `wip-cap` |
| unknown | any | not compared |

When a lane input could not be read (decisions, stack-wait, the pool log,
overlap-schedule), the verdict lines are still written, the tick posts
`compared=0` with no diffs and names the input in `partial`. When a required
input could not be read (the issue listing, edges, holds, jobs, the
`pr_state` ledger, claims, preplans; a 404 counts), the lane writes one
`skipped=inputs reads_failed=<names>` line and posts nothing.

## Lines

`logs/scheduler.log`:

- `SCHED ticket=<KEY> ready=yes|no|unknown reason=<reason>`, one per judged
  candidate.
- `SCHED-TICK project=<p> mode=shadow at=<AT> candidates= ready= not_ready=
  unknown= in_flight= compared= agreed= idle= diffs= post=ok|failed:<http>
  partial=<names|->`. `post=ok` only after a 2xx with `ok:true`, and only
  then is `state/scheduler/<p>.last` written.
- `SCHED-TICK project=<p> mode=off`, or `skipped=no-prefix|no-slug|inputs`.

## Settings rows

- `scheduler.mode` = `shadow`. `off` stops the lane after one line. Any other
  value (`enforce` included) runs shadow and logs `mode=<v> not built in this
  wave`.
- `scheduler.projects` = `cromford`, the list `--all` reads.
- `scheduler.parent_reads_max` = `20`.
- `retention.sched_diffs.days` = `30`, `retention.sched_ticks.days` = `30`.

## Assumptions

- A1. "PR state from the pr_state view" is read from the `pr_state` ledger
  rows, the view's source of truth, while the view answers 404.
- A2. "hold row" is a `ticket_holds` row (#6977). Until the `ticket-holds`
  wake class is armed, few hold rows exist, and the lanes' own HOLD handling
  shows as `lanes-held:triage` disagreements.
- A3. "the same tick" is the window since the previous scheduler tick.
- A4. idle (ready, and no lane acted) is not a disagreement. The digest prints
  the idle count next to the rate.
- A5. "wip cap" is `bin/free-slots.sh <project>`. cromford is
  Fly-routed, so it prints `unlimited` and no ticket gets `wip cap` today.

## Checks

- `HARNESS_TEST_SANDBOX=1 bash tests/scheduler-shadow.bh-6978-test.sh`
- `cd worker/jobs && node --test test/scheduler.bh-6978.test.js`
- On the hub after deploy: `grep 'SCHED-TICK project=cromford' /root/harness/logs/scheduler.log | tail -1`
  shows `post=ok` less than 10 minutes old, and
  `curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/scheduler/agreement?day=$(date -u +%F)"`
  answers `ok:true` with a `cromford` entry.
