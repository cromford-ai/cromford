# web-task human step: the resume-run enqueue (BH-8360, slice C0)

Doc: DB-COORDINATION-SPEC

Follows [the BH-7598 note](2026-10-23-BH-7598-web-task-human.md) (the human
step) and [the BH-8314 note](2026-10-25-BH-8314-web-task-human-resume.md) (the
resume route).

## What changed

`POST /api/web-task/answer` (`worker/jobs/src/routes/web-task-human.js`) can
enqueue one new `web-task` lane run when a person answers a step whose run has
stopped. The settings row `web_task.resume_enqueue` turns it on.

- `0` (the seed, and the code default for a missing row or any value that is
  not `0` or `1`): off. The route is unchanged: one UPDATE, the answer
  `{ok, step_id, status}`.
- `1`: for an `answered` status, the answer UPDATE and `RESUME_ENQUEUE_SQL`
  run as one D1 batch. The INSERT copies the asking run's `lane`, `project`
  and `args_json` into a new `queued` row with
  `enqueued_by = 'web-task-resume:<step_id>'`. It inserts only when all of
  these are true:
  - the answer UPDATE changed one row (`changes() = 1`), so a lost race
    inserts nothing;
  - the step is `answered`;
  - the asking run is `lane = 'web-task'` and `status` is `done` or `died`;
  - no other `queued` or `claimed` web-task run of that project exists
    (`lane_runs_live`, the INSERT is `OR IGNORE`).
- A `cancel` answer never enqueues (the person said stop).

## The answer

With the switch on and status `answered`, the 200 adds two or three fields:

| `resume` | `resume_run_id` | `resume_why` | meaning |
|---|---|---|---|
| `enqueued` | the new `lane_runs.id` | (absent) | the INSERT changed one row |
| `skipped` | `null` | `run_live` | the asking run is `queued` or `claimed` (live, or its lease passed: the lane-run claim re-takes that row with the same id, and the run resumes its own step) |
| `skipped` | `null` | `already_live` | the asking run stopped, but another web-task run of the project is live |
| `skipped` | `null` | `not_web_task` | the step's run is not a web-task run |
| `skipped` | `null` | `not_enqueued` | none of the above |

The answer is recorded in every case. A skipped enqueue never fails the answer.
The 409, 410, 403 and 400 refusals are as before, and they write no row.

Statements: off is 2 parallel reads and 1 UPDATE. On and enqueued is 2 reads
and a batch of 2. On and skipped adds 1 read (`RESUME_SKIP_SQL`), 5 in total.
Every lookup is a PRIMARY KEY or `lane_runs_live` probe (test X1).

## Why the worker may enqueue a web-task run

`webTaskEnqueueRefused` (web-vault.js) lets only the operator token enqueue a
`web-task` run on the HTTP routes. That route is not changed. The in-worker
enqueue is allowed because:

1. It copies the `args_json` of a run the operator already enqueued.
2. It fires only after a bearer-gated answer that carries the step nonce. Only
   the operator got that nonce.
3. It fires at most once per step: the answer UPDATE is conditional on
   `status = 'open'`, and the INSERT runs only when that UPDATE changed one row.
4. It is off until the row is 1.

## The race this slice does not close

An answer that lands after the run's last poll, but before its row becomes
`done`, enqueues nothing: `resume: skipped`, `resume_why: run_live`. The step
stays `answered` until its `expires_at`. An operator enqueue, or a finish hook
in slice C1, can still resume it through `POST /api/web-task/human/resume`.

## Owed to slice C1 (after #7650 merges)

1. Fill `bin/lib/web-task/approval.sh`. The file exists only on open PR #7650.
2. The S1 web-task lane reads `enqueued_by`. If it starts with
   `web-task-resume:`, the lane calls `createHumanStep(...).resume` with that
   step id, and does not start the task fresh.
3. Set `web_task.resume_enqueue` to 1. Until then the new row has no
   consumer, so the seed stays 0.
4. A real proof on the operator's phone:
   1. Set `web_task.resume_enqueue` to 1.
   2. Run a web-task ticket on a site with SMS 2FA.
   3. Let the 300 s wait pass, so the run stops.
   4. Answer the code on Telegram.
   5. See the new lane run start, resume the step and finish the task.

## Check after deploy

`SELECT value FROM settings WHERE key='web_task.resume_enqueue'` gives `0`.

## Tests

`worker/jobs/test/web-task-resume-enqueue.bh-8360.test.js`: real `worker.fetch`
on node:sqlite with the composed schema. E1 claims the new row through
`POST /api/lane-runs/claim`, takes over the step with the BH-8314 route and
polls the code once.
