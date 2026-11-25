# BH-9934: the GitHub receiver's coverage and hardening

Doc: EVENTS

Wave 2 of #9926 (BH-9926.2). Route `POST /webhooks/github` in
`worker/jobs/src/routes/webhooks.js`; helpers in
`worker/jobs/src/lib/webhook-receiver.js`.

## What changed

- **Body cap before the HMAC.** A `Content-Length` over the cap, or a body
  stream that passes it, is `413 {error:"payload too large", cap}`. The rest
  of the body is not read, and nothing is written. The cap is the settings row
  `webhook.github.max_body_bytes` (seed 5242880, valid 1024..26214400; the
  code fallback is `WEBHOOK_MAX_BODY_BYTES`, 5242880). The row is read from
  the in-memory settings snapshot only, so an unsigned caller causes no D1
  read. A cold isolate uses the fallback until the snapshot is warm.
- **Label wakes.** `pull_request` `labeled` and `unlabeled` for the labels
  `merge-queue`, `dequeued` and `merge-queue-paused` give a `pr` wake. The wake
  event is `pull_request.<action>.<label>` (for example
  `pull_request.labeled.dequeued`). `labeled queued` keeps the event
  `pull_request.labeled`, which `bin/lib/wake-class-pr-closed.sh` reads as
  "queued". The new events match no shell wake class (pinned by
  `tests/wake-label-events.bh-9934-test.sh`); `bin/merge-conductor-wake.sh`
  takes every `pr` wake.
- **Self-App filter.** A delivery whose `sender` has `type: "Bot"` and a login
  in `HARNESS_SELF_APPS` (`app/x`, `x[bot]` and `x` are all `x`) and whose
  `<event>.<action>` is in the row `webhook.github.self_echo_actions` writes
  the PR record and the gate rows, and NO wake. The answer is
  `202 {ok:true, ignored:"self-app", app}`. Default pairs:
  `pull_request.labeled pull_request.unlabeled issue_comment.created issue_comment.edited`.
  Every handoff action (`opened`, `synchronize`, `closed`, CI results) stays a
  wake. Set the row to `""` to turn the filter off. `bin/harness-sync.sh`
  passes the list as `--var HARNESS_SELF_APPS:<list>` to `wrangler deploy`
  (resolved by `bin/lib/harness-self.sh` from `env/global.env`). An empty list
  passes no var, and then nothing is filtered.
- **Record and wake in one batch.** On a wake with a delivery id, the PR
  record statements run in the same D1 batch as the delivery row and the wake
  row. The delivery row stores a random `claim`, and each record statement
  runs only while the row holds its claim. Twenty identical deliveries make
  one delivery row, one wake and one record write. Other deliveries
  (no wake, no delivery id, a self echo) write the record as before.
- **Dead letter.** A throw after the signature check writes one
  `webhook_deliveries` row with vendor `github:dead`, the delivery id (or
  `none:<uuid>`), the event and the error (300 chars), and answers
  `200 {ok:true, dead_letter:true, delivery_id}`. GitHub then does not
  redeliver in a loop. The failed batch committed nothing, so a manual
  redelivery runs again. If the dead-letter write also fails, the answer is
  500. The rows age out with the 7-day delivery prune
  (`webhook_delivery_keep_s`).
- **Dead-letter alert.** `GET /api/webhook-dead-letters?vendor=github`
  (bearer) answers `{vendor, count, newest_at, newest, as_of}`.
  `bin/doorbell-coverage-check.sh` (daily, hub) reads it and writes one
  `[doorbell]` ALERTS line plus one `fleet_alert` beat (akey
  `webhook-dead-letter:github`) while the count is above 0. Its flag is
  `flags/webhook-dead-letter-github`. At count 0 it removes the flag and
  resolves the console row. A failed read logs `dead-letters check failed`.

New `webhook_deliveries` columns (`core.d/bh-9934-webhook-deliveries.js`,
through `ensureColumns`): `claim`, `error`, `event`. No new table.

## The App-level webhook (operator option, not armed by this wave)

The fleet authenticates as GitHub Apps. An App can carry ONE webhook for every
repo it is installed on, so there is no per-repo hook to keep in sync with
fleet.conf. This wave does not switch to it. To switch, an operator:

1. Opens the GitHub App's settings page (a person, in the browser).
2. Sets the webhook URL to `$JOBS_URL/webhooks/github` and the secret to the
   same `GITHUB_WEBHOOK_SECRET` the worker holds (pasted by hand; it is in no
   env file on a box).
3. Subscribes it to the canonical events (`bin/webhook-rearm.sh --print-events`).
4. Grants the App the read permissions those events need: Commit statuses,
   Actions and Merge queues (read), next to the permissions it already holds.
5. Runs `bin/doorbell-coverage-check.sh`. It already reports a repo the App
   hook covers as `armed-app`.
6. Removes the per-repo hooks after the switch. A repo with both an App hook
   and a repo hook gets each event twice, with two delivery ids, so the
   delivery dedupe does not merge them (the minute dedupe on `wakes` still
   merges the two wakes, but the gate and record writes run twice).

## Arming report from the build (2026-11-24)


The build ran `bin/webhook-rearm.sh --dry-run` once (2026-11-24, build box pool-cromford-811d650b324958). It ran read only; the build never runs `--apply` and creates no hook. Exit code 0. Verbatim output:

```
UNREADABLE example-org/project-1 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-2 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-3 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-4 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-5 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-6-runtime — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-8 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-9 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-7 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/cromford — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/cromford-console — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/cromford-web — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-6 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-6-desktop — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-21 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/cromford-sandbox-linear — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/cromford-sandbox-jira — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-4-site — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-12 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-14 — no PAT here holds admin:repo_hook (env/github-admin.env)
UNREADABLE example-org/project-13 — no PAT here holds admin:repo_hook (env/github-admin.env)
webhook-rearm mode=dry-run repos=21 ok=0 would_patch=0 failed=0 unarmed=0 unreadable=21 inactive=0
```

All 21 repos are UNREADABLE from the build box: no PAT here holds `admin:repo_hook`. This box cannot tell which repos are armed. An operator must do these steps on the hub, for each repo below:

1. Run `bin/doorbell-coverage-check.sh` to see the coverage per repo.
2. Run `bin/webhook-rearm.sh --dry-run`.
3. If a repo shows `WOULD PATCH`, run `bin/webhook-rearm.sh --apply --repo <repo>`.
4. If a repo shows `NO_REPO_HOOK`, create the hook by hand (docs/EVENTS.md 4.3; paste the shared secret).

- `example-org/project-1`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-2`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-3`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-4`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-5`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-6-runtime`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-8`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-9`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-7`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/cromford`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/cromford-console`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/cromford-web`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-6`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-6-desktop`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-21`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/cromford-sandbox-linear`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/cromford-sandbox-jira`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-4-site`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-12`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-14`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
- `example-org/project-13`: UNREADABLE here. Operator: run the dry run on the hub, then arm per its line.
