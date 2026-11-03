# web-task write mode: the BH-7599 write gate in the agent and the lane (BH-8299)

Doc: OPERATING, PROJECT-LANES

## What changed

BH-7599 (PR #8296) shipped the write gate `bin/lib/web-write-step.mjs` with no
caller. The agent refused every submit-like click, and its network guard
aborted every non-GET request. This change wires the gate in. It is slice C0
of #8299. The live proof on a real account is C1 of #8299, after merge and
deploy (see "Operator steps").

- A ticket asks for write mode with `Mode: write` on its own line in the
  issue BODY. `bin/web-task.sh` reads it with `parseTaskMode`. The title and
  the comments never count. A quoted `> Mode: write`, a line inside a code
  fence, `Mode: writer`, no line, or a parse that fails is a read run.
- `bin/web-task-agent.mjs --mode read|write` (default `read`). Any other value
  is status `error` before the browser starts.
- Every click and type of the agent goes through ONE gate per run. The gate
  is built at the first click or type. Its site is the page host then.
  - A payment page whose host is not in `ALLOW_PAYMENT_SITES` is refused in
    every mode, by click and by type. The refusal kind is `payment` and the
    run stops.
  - Read mode: a write control is refused with S1's exact text and refusal
    kind `control`. Read runs keep S1 behavior.
  - Write mode: a write click waits for one Approve through S5's
    `wh_request_human ... approve`, with the before-shot. Cancel, no answer in
    `WEB_TASK_WRITE_WAIT_S`, or an approval error stops the run with nothing
    written.
  - A typed value is never a write and asks no approval.
  - A write click on another host than the gate's site is refused:
    `refused: this run writes on <site> only`.
- The approved-write window. While one approved write click runs
  (`st.approved`), a non-GET request to an allow-listed host passes. Its
  navigation goes through `writeNav`: every hop must pass the allow-list, and
  a 307/308 repeats the request only on an allow-listed host. If any request
  is refused or aborted in the window, or the click throws, the write is
  recorded `unknown`. It is never retried, and the run stops. The window
  closes when the click and its settle return. A request one step later is
  refused as before (kind `method`).
- `isSubmitLike` of `bin/lib/web-task/guards.mjs` is now `isWriteAction`: one
  classifier. It also refuses `update` and `apply` in read mode.
- The decide prompt: `WEB_TASK_MODE=write` gives the write-mode rules. Any
  other value prints the read-only rules byte for byte.

## result.json

Two new fields:

- `mode`: `read` or `write` (`""` for a bad `--mode`).
- `writes`: the gate's `writes()`, `[{n, action, before, after, status}]`.
  `status` is `done` or `unknown`. `[]` when no write ran.

A stopped write run ends with status `error`. The reason is
`stopped: <what stopped it>`, for example
`stopped: write 1 cancelled; nothing written`.

## The lane

- Env for the agent: `WEB_TASK_MODE`, `WEB_TASK_ISSUE=<owner/repo>#<n>` (the
  approval's board fallback), `ALLOW_PAYMENT_SITES` from the settings row
  `lane.web-task.<project>.allow_payment_sites` (no row, an empty row or a read
  failure is empty, so every payment page is refused), and the
  `WEB_TASK_WRITE_WAIT_S` knob through `lib_env_apply web-write`.
- Screenshots: the write shots (each write's before, then after, in write
  order) go first, then the step shots, in ONE `wt_shots_publish` call. The
  total stays under `WEB_TASK_MAX_SHOTS`. A write shot past the cap shows
  `none` in the Writes table.
- The comment in write mode opens with "I ran this web task in a browser in
  write mode. Each change waited for an approval." A `### Writes (n)` table
  (`writesSection`) comes before `### What I did`. The refusal heading is
  "What the guard refused". A read-mode comment does not change, except that a
  payment refusal has its own line in every mode.

## Operator steps

The live proof (C1 of #8299) runs after this change is deployed. In order:

1. Precondition: this PR is merged and the lane-run image runs the merge sha.
2. Done by the operator (issue comment 6578929813):
   `lane.web-task.project-6-os.allowed_domains=os.example.com` and
   `lib.lane-alert.lane_alert_dm_chat`.
3. Owed, the operator (6539742813 part 2): the `TELEGRAM_BOT_TOKEN` secret on the
   lane-run app. Without it `wht_send` skips, and only the board fallback
   works.
4. Owed, cromford-console (6539742813 part 3): forward the `wt:<step>:<nonce>:d|c`
   callback presses to `$JOBS_URL/api/web-task/answer` (the route in
   `worker/jobs/src/routes/web-task-human.js`). This is not in this repo.
   Until then a Done press does nothing. `HUMAN-STEP-DONE: done` on the issue
   by a `web_task.human_logins` login approves.
5. Owed: the QA owner credential for os.example.com in the web vault of
   project project-6-os, and a TOTP seed if the account has one.
6. File ONE issue on example-org/project-6, labels `web-task` and `ai-build`.
   Body: `Mode: write` on its own line, then "Sign in on
   https://os.example.com and change the display name of the QA company to
   `<name the operator picks>`. Then read it back and answer with the new name."
7. the operator presses Approve in Telegram on the one write.
8. Evidence: the result comment has `### Writes (1)` with status `done` and
   before and after links, and the answer quotes the new name. If the site
   asked for a code, the actions list shows `type_otp` with an `ok:` outcome
   (the #8289 proof). If not, the comment says so, and the OTP proof stays
   owed.

## Tests

`tests/web-task-write-mode.bh-8299-test.sh`: the real agent and a real
chromium on a 127.0.0.1 fixture site with a stub `web-human.sh` (A1-A11), the
real lane with stub GitHub and settings (L1-L5), and the decide rules (D1-D2).
`tests/web-task-lane.bh-7594-test.sh` installs `bin/lib/web-write-step.mjs` in
its scratch lane tree, because the agent now imports it.
