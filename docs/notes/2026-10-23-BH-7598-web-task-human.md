# web-task human step: a person completes a 2FA step (BH-7598, slice C0)

Doc: DB-COORDINATION-SPEC

## What changed

Some sites need a person for the second factor: a push approval on a phone,
or a code sent by SMS. This slice adds the store, the three worker routes, the
client `wh_request_human` and its two vendor seams. It does not wire the
client into the web-task agent loop and it does not add the resume run. Those
need the files of #7594 (web-task S1, PR #7650) and the saved sessions of
#7597 (S4). They are slice C1.

- Table `web_task_human_step` (`worker/jobs/schema.d/202610251632-bh-7598-web-task-human.sql`).
- Routes in `worker/jobs/src/routes/web-task-human.js`:
  `POST /api/web-task/human/ask`, `POST /api/web-task/human/poll`,
  `POST /api/web-task/answer`.
- Client `bin/lib/web-human.sh` (`wh_request_human`).
- Seams `bin/lib/web-human/telegram.sh` (`wht_send`) and
  `bin/lib/web-human/board.sh` (`whb_post`, `whb_done_after`).
- `sha256Hex` and `sameText` in `worker/jobs/src/routes/web-vault.js` are now
  exported. Their bodies did not change.
- Retention rule `web_task_human_step.age` in `worker/jobs/src/routes/retention.js`.

## The flow

1. The run calls `wh_request_human <project> <site> <code|approve> <prompt> [--shot <png>] [--issue <owner/repo#n>]`.
2. The ask route checks the run like a vault read (`readRefusal` of
   web-vault.js: the claimed run, the machine, the run token, the lease, the
   project, the allow-listed site). It sets the run's open step to
   `superseded` and inserts the new step, in one batch. The answer holds the
   nonce (16 random bytes, base64url, 22 characters). D1 keeps its SHA-256 only.
3. The client sends ONE Telegram message to the chat of the settings row
   `lib.lane-alert.lane_alert_dm_chat`: a photo with the screenshot when
   `--shot` is given. The text holds the project, the site, the step and the
   line `ref: wt:<step>:<nonce>`. The buttons are "Done" and "Cancel" for
   `approve`, "Cancel" for `code` (a code is a reply to the message).
4. The client posts ONE comment on `--issue`. Its first line is
   `NEEDS-HUMAN: web-task <kind> on <site>: <prompt>`, so `bin/lib/hold.sh`
   holds the ticket. The comment ends with `<!-- wt-step:<step> -->`. It never
   holds the nonce.
5. The client polls every `web_task.human_poll_s` until `wait_until`. Between
   polls it reads the issue. A comment whose FIRST line is
   `HUMAN-STEP-DONE: <code|done>`, by a login of `web_task.human_logins`, not a
   bot, and newer than the hold comment, goes to the answer route with
   `via=board`. The answer route stays the one writer.
6. Outcomes: rc 0 (the code on stdout, or `done`), rc 3 (`web-human: cancelled`),
   rc 4 (`web-human: waiting on human (step <id>)`; the step stays `open`
   until `expires_at`, so a later answer is kept for the resume run of C1),
   rc 1 (a refusal, no channel delivered, a failed poll), rc 2 (usage or env).
   If neither channel delivered the ask, the client cancels the step first.

## The answer decision (`POST /api/web-task/answer`)

Bearer-gated. The body is a plain answer
`{run_id, step_id, nonce, action: done|cancel|code, code?, via?: api|board|telegram}`,
or a Telegram update as the bot receives it:
`{callback_query: {data: "wt:<step>:<nonce>:d|c"}}`, or
`{message: {text: <code>, reply_to_message: {text|caption: "...\nref: wt:<step>:<nonce>"}}}`.
The `ref:` line must start a line, so a quoted (`> ref:`) or mid-line ref is
not a ref. The first failing check wins:

| check | answer |
|---|---|
| bad form, unknown action, a code not `[A-Za-z0-9-]{1,32}` | 400, nothing written |
| no step for the nonce, or another step id | 403 `bad_nonce` |
| a plain answer whose run_id is not the step's run | 403 `other_run` |
| the step was superseded by a newer ask | 409 `old_nonce` |
| the step is answered, consumed or cancelled | 409 `already_answered` |
| `expires_at <= now` | 410 `expired` |
| a code on an approve step, or done on a code step | 400, nothing written |
| the vault key is missing | 503, nothing written |
| else ONE conditional UPDATE (`status='open'`, not expired) | 200 `{ok, step_id, status}` |

A code is stored as AES-GCM ciphertext with the web_vault key
(`web_vault.key_id`, aad `web-task-human:<step>`). The answer never echoes it.

## The poll (`POST /api/web-task/human/poll`)

The same run check as the ask, and the step must be the run's (403
`other_run`). `open` is `pending`; `cancelled`; `consumed` has no code;
`superseded` is 409 `old_nonce`. An `answered` step is set to `consumed` in
ONE conditional UPDATE that also sets the ciphertext to NULL. The code (or
`done`) leaves only when that UPDATE changed one row. So a code is used once.
The first poll carries `tg_outcome` and `board_outcome`; each is written once.

## Knobs (settings rows, all seeded)

| row | seed | bounds | read by |
|---|---|---|---|
| `web_task.human_wait_s` | 300 | 10..3600 | ask, as `wait_until`. `WEB_TASK_HUMAN_WAIT_S` on the box can only shorten it. |
| `web_task.human_poll_s` | 5 | 1..60 | ask, as `poll_s` |
| `web_task.human_answer_ttl_s` | 86400 | 60..604800 | ask, as `expires_at` (never before `wait_until`) |
| `web_task.human_logins` | `operator` | comma list | ask, as `logins` (no row: no board answers) |
| `retention.web_task_human_step.days` | 30 | 0 = off | the hourly retention run, under `retention.dry_run` |

The box-side HTTP timeouts are lib knobs in `catalog/lanes.d/_lib.web-human.json`:
`WEB_HUMAN_TIMEOUT_S` (15 s, row `lib.web-human.web_human_timeout_s`) and
`WEB_HUMAN_CONNECT_TIMEOUT_S` (5 s, row `lib.web-human.web_human_connect_timeout_s`).
The lib applies the rows with `lib_env_apply web-human` when its caller has
loaded `bin/lib/lane-gate.sh`; else the env or the fallback holds.

The Telegram chat is the existing row `lib.lane-alert.lane_alert_dm_chat`. No
row: the ask answers `tg_chat: null`, the Telegram channel is
`not-configured: chat`, and the board comment still goes out.

## Operator steps

- Set `TELEGRAM_BOT_TOKEN` as a secret on the lane-run app that runs
  web-task. Without it the Telegram channel answers
  `not-configured: TELEGRAM_BOT_TOKEN` and only the board comment goes out.
- The console backend owns the bot webhook. It must forward each Telegram
  update whose `callback_query.data` starts with `wt:`, or that replies to a
  message with a `ref: wt:` line, verbatim to `$JOBS_URL/api/web-task/answer`
  with the bearer. That repo is not this one (C1).

## Still owed (slice C1)

- Wire `wh_request_human` into the web-task agent loop and the S1 seam
  `bin/lib/web-task/approval.sh` (the browser that stays open is the S1 agent's).
- The resume run: a later answer starts a new run from the saved session (S4).
- The console forward of Telegram updates (above).
- A real proof on one site with push approval or SMS 2FA to the operator's phone.
