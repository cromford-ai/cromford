# web-task human step: the page half and the resume run (BH-8314, slice C0)

Doc: DB-COORDINATION-SPEC

## What changed

BH-7598 (slice C0) added the store, the ask, poll and answer routes, and the
client `wh_request_human`. This slice adds the two parts of the rest of #7598
that need no file of #7594 (web-task S1, PR #7650):

1. `bin/lib/web-human-step.mjs`: `createHumanStep` returns `askHuman` and
   `resume`, and `readResume` reads a resume record. `askHuman(page, {kind, prompt})`
   is the page half of `request_human(kind, prompt)`. It holds the run's page
   open while `wh_request_human` waits. It types the person's code into that
   page. On no answer it saves a resume record.
2. The worker route `POST /api/web-task/human/resume`
   (`worker/jobs/src/routes/web-task-human-resume.js`, fragment
   `worker/jobs/test/route-table.d/bh-8314-web-task-human-resume.txt`) and the
   client `wh_resume_human <project> <site> <step>` in `bin/lib/web-human.sh`.
   A new claimed run of the same project and site takes over the step of a run
   that stopped, then polls it once. Before this, the poll refused every run
   but the asker (403 `other_run`).

No table, index or migration is added. `wh_request_human` is not changed.

## The page half

`askHuman(page, {kind, prompt})`, in order:

1. `kind` is `code` or `approve`. `prompt` is one line of 1..512 bytes. Else `invalid: ...`.
2. The host gate of `bin/lib/web-signin-step.mjs` on `page.url()`. Else `refused`.
3. For `code`: the code input must exist, and its form target and the submit
   control's target must pass the gate. Else `error: no code field` or `refused`.
4. A screenshot (password and code inputs masked) into a new 0700 temp dir.
   The dir is deleted when the ask returns, on every path.
5. `wh_request_human` in a bash child. Its argv holds no code. The wait is the
   row `web_task.human_wait_s` (300 s). `WEB_TASK_HUMAN_WAIT_S` can only make
   it shorter. The module makes no page call during the wait and never closes
   the page.
6. rc 0: the code is typed into the same input and submitted, or the
   approval is taken. rc 3: `stopped: cancelled by a person`. rc 4: the resume
   record is saved, and the outcome is
   `stopped: waiting on human (step <id>); resume record saved`.
   If the save fails, the outcome says `resume record not saved (<why>)`.

The full outcome list is in the module header.

## The resume record

`<stateDir>/<step>.json` holds `{v:1, project, site, kind, step_id, run_id, url, storage, saved_at}`.
`<stateDir>/<step>.storage.json` holds the page context's `storageState()`
(cookies and local storage). Both files are mode 0600 and are written to a
temp file, then renamed. The dir is mode 0700. Neither file holds a code, a
nonce or a token.

`stateDir` comes from, in order: the option, `WEB_TASK_HUMAN_STATE_DIR`,
`$HARNESS_STATE/web-task-human`, `$HARNESS/state/web-task-human`. If none is
set, the record is not saved and the outcome says so. The lib never falls back
to a `/root/harness` path (build-discipline D43).

Retention: each save deletes the record pairs saved before
`WEB_TASK_HUMAN_RESUME_KEEP_S` (default 604800 s, the top of the
`web_task.human_answer_ttl_s` bounds). A resume deletes the record pair on
rc 0, rc 3, a refusal and a consumed step. It keeps the pair on rc 4 and when
the worker is unreachable.

`resume(page, record)` checks that the record has the instance's project and
site. It runs the gates of steps 2 and 3, then runs `wh_resume_human`. On
rc 0 it types the code (or takes the approval) as in step 6.

## The route

`POST /api/web-task/human/resume {run_id, machine, project, site, step_id}`,
bearer-gated, plus the new run's `x-web-vault-run-token`. Four reads run in
parallel: the new run (PK), its token row (PK), the settings (the cached
read), and the step joined to its old run (both PK). At most one write
follows. The first failing check wins:

| check | answer |
|---|---|
| bad form | 400, nothing written |
| `readRefusal` of the new run | 403 `no_run`, `wrong_lane`, `not_claimed`, `not_claimer`, `bad_token`, `lease_expired`, `wrong_project`, `site_not_allowed` |
| no step | 404 `no_step` |
| the step's project or site is not the body's | 403 `other_task` |
| the step is already this run's | 200, nothing written |
| superseded / consumed / cancelled | 409 `old_nonce` / `already_answered` / `cancelled` |
| `expires_at <= now` | 410 `expired` |
| old run `claimed` and its lease not passed | 409 `run_live` |
| the conditional UPDATE changed 0 rows | 409 `raced` |
| else | 200 `{ok, step_id, status, kind}` |

The UPDATE is `SET run_id=<new> WHERE id=<step> AND run_id=<old> AND status IN ('open','answered') AND expires_at > now`.
Two resume runs therefore cannot both take one step. The answer never holds a
code or a nonce. The poll route is not changed: its check `step.run_id = run`
now serves the new run.

`lane_runs_live` allows one queued or claimed run per (lane, project). So
today `run_live` and `raced` cannot happen for one project. A reclaimed run
(the claim of an expired lease takes the same row) gets the "already this
run's" 200. The two guards stay in case that index changes.
Statement count on the 200 path: 4 reads and 1 UPDATE
(`worker/jobs/test/web-task-human-resume.bh-8314.test.js` R10).

## Knobs

Lib id `web-human-step` (`catalog/lanes.d/_lib.web-human-step.json`):

- `WEB_TASK_HUMAN_STEP_TIMEOUT_S` (row `lib.web-human-step.web_task_human_step_timeout_s`):
  5..120, default 20. The page wait after the submit.
- `WEB_TASK_HUMAN_RESUME_KEEP_S` (row `lib.web-human-step.web_task_human_resume_keep_s`):
  3600..604800, default 604800. How long a resume record stays on disk.

A bad value throws. It is never clamped.

## Owed to slice C1 (after #7650 merges)

- `bin/lib/web-task/approval.sh` (it exists only on PR #7650) calls
  `createHumanStep`, and the S1 agent loop passes its Playwright page to
  `askHuman`. Today the module has no production caller.
- The trigger that enqueues the resume run when a late answer lands. A
  web-task enqueue needs the operator token (`webTaskEnqueueRefused` in
  `worker/jobs/src/routes/web-vault.js`), so this is an auth decision.
- The resume run opens its browser context with the record's storage file,
  then calls `resume(page, readResume(file))`.
- The console forward of Telegram updates to `/api/web-task/answer` (#7598 A2).
- The real proof on the operator's phone: one real 2FA site, one real Telegram DM,
  one reply, and one resume after a timeout.

## Tests

- `worker/jobs/test/web-task-human-resume.bh-8314.test.js`: the decision table
  through `worker.fetch` on node:sqlite, the poll after a rebind, the statement count.
- `tests/web-human-step.bh-8314-test.sh`: the module on a fake page, the
  knobs, `wh_resume_human` against the real worker, and both default seams end
  to end with the Telegram fake and the 2FA fixture site.
