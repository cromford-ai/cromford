# BH-9672: end the PLAN_STALE loop on a resumed ticket

Doc: RUN-BUILD-GRAPH, PREPLAN

## Why

A build on a branch that already carried commits adopted the coordination DB
pre-plan (`PREPLAN_HIT adopted .../preplan-db`). The plan thread gate (BH-5799)
refused it for an uncited newer comment. The branch had a diff, so the run
ended `PLAN_STALE uncited comment(s) newer than the plan: <ids> — re-plan`
(exit 3). The gate removed only a hub `plans/` dir. The DB row stayed, so the
next build adopted the same row and ended the same way. BH-8841 did this 4
times and BH-9513 2 times. No plan stage ran in any of those builds, and the
RESULT said "re-plan" when nothing re-planned.

## What changed

- `bin/lib/plan-stale-replan.sh` (new lib, knobs in
  `catalog/lanes.d/_lib.plan-stale-replan.json`).
- Adopt step (`# >>> preplan adopt`, `bin/lib/rb/plan.sh`): after
  `preplan_check` passes, `psr_adopt_check` runs `ptg_check` on the pre-plan
  against its own stamp. A refusal is
  `PREPLAN_STALE ... (uncited comment(s) newer than the pre-plan: <ids>)`, the
  DB row is retired and the plan stage runs in the same build. An unreadable
  thread adopts as before, with one `plan-thread: adopt check fails open` line.
- Retire at the source: `psr_retire` removes the hub dir (as before) and calls
  `POST /api/preplans/retire {project, ticket_key, thread_at_max}`
  (`worker/jobs/src/routes/preplan-retire.js`). The DELETE keeps a row whose
  `thread_at` is newer than the refused stamp. One `preplan-retire:` line per
  retire. A failure is named in the RESULT (`db retire failed (...)`).
- Plan thread gate, call site A: the refusal retires the DB row. On a resumed
  branch, a refusal whose id set equals an earlier build's
  `PLAN_STALE uncited comment(s) ...` RESULT (newest `PSR_LOOKBACK` jobs rows of
  the ticket, then local build dirs) writes one
  `PLAN_STALE_REPEAT [<project>/<key>] ids=<ids>:` line to ALERTS and plans
  fresh in the same run. The first refusal still ends PLAN_STALE (exit 3).
- New block `# >>> replan on branch (BH-9672)`: a fresh plan on a branch with a
  diff over BASE and a resume signal gets the branch commits, the diffstat and
  the refused ids in `REPLAN_LINE`, and must write `## Existing branch commits`
  (`- <sha> keep|drop: <reason>`). It writes `$BUILD/replan-on-branch`.
- `rb_execute`: the checkpoint skip is not taken when `$BUILD/replan-on-branch`
  exists. The execute note lists keep, revert and undecided commits. The
  marker becomes `replan-on-branch.done` after a good execute.
- Call site B (`rb_review`): retires an adopted pre-plan, alerts once on a
  repeat (`at review`) and still ends PLAN_STALE.
- RESULT text at both call sites:
  `PLAN_STALE uncited comment(s) newer than the plan: <ids> — refused plan retired (<outcome>); the next build of <KEY> plans fresh with this branch's commits in its prompt`.
  Every reader matches the `PLAN_STALE` word or the prefix before the dash.

## Knobs

`lib.plan-stale-replan`: `PSR_ADOPT_THREAD_CHECK` (1), `PSR_REPEAT_FRESH` (1),
`PSR_LOOKBACK` (5), `PSR_COMMITS_MAX` (30). 0 turns either switch off.

## How to see it on a box

`grep -h 'PREPLAN_STALE\|preplan-retire:\|replan-on-branch:\|PLAN_STALE_REPEAT' /root/harness/builds/cromford-*/pipeline.log /root/harness/logs/ALERTS.log`

Tests: `tests/plan-stale-replan.bh-9672-test.sh`,
`worker/jobs/test/routes/preplan-retire.bh-9672.test.js`.
