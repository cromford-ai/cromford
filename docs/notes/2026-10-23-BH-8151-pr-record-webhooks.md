# BH-8151 (BH-8067 slice C2): webhooks write the PR record

Doc: DB-COORDINATION-SPEC

What changed:

- `POST /webhooks/github` now writes the `pr_records` row of each PR a signed
  delivery names. The writer is `recordPrRecord` in
  `worker/jobs/src/lib/pr-record-intake.js`. It runs after the signature check
  and before `wakeOf`, sends one D1 batch per delivery, and never throws. The
  receiver's status and body do not change. A failed write is one
  `[pr-record-intake]` console warn; the max-age backstop heals the record.
- Events and what they write (source `webhook`):
  - `pull_request` (every action): state (`merged` when merged), draft, refs,
    shas, labels. `mergeable_state` is written when GitHub sends a known word.
    On `opened`, `reopened`, `synchronize` and `edited` an absent or
    `unknown` value is stored NULL.
  - `pull_request_review` (`submitted`, `edited`, `dismissed`): the PR fields
    and `review_decision` (`approved`, `changes_requested`, NULL on dismiss).
  - `issue_comment` (`created`, `edited`, on a PR only): labels and state.
  - `check_run` (`created`, `completed`), `check_suite` (`completed`),
    `workflow_run` (`completed`): one `checks` entry per PR,
    `{status, conclusion, sha, at}`, keyed `<check name>`, `suite:<app slug>`
    or `workflow:<name>`. The prequeue dispatch run takes the PR and head from
    its title. An entry is replaced only by a newer one; the object holds at
    most 100 names.
  - `push` to the default branch: `mergeable_state` NULL on every open row of
    that repo whose base is that branch.
- Each write is ordered by the event's own time (clamped to the worker's
  clock) through the same per-field guard as the PUT: an older delivery never
  replaces a newer fleet or GitHub value.
- Check, comment and push writes do not move `refreshed_at` on an existing
  row, so the `PR_RECORD_MAX_AGE_S` backstop still sees a record that only
  check deliveries touched. `upsertSql` takes `{refresh}` for this; its
  default SQL is unchanged.
- Case 2 of the read rule: `PUT /api/pr-records` accepts `mergeable_state:
  null`, and `bin/lib/pr-record.sh` stores GitHub's `mergeable_state:
  "unknown"` as null. The next `pr_record_get` that asks for
  `mergeable_state` reads GitHub again (`reason=field:mergeable_state`).

Not written by webhooks: `last_comment_id` and `queue_state` (fleet writes,
slice C1). No lane reads the record yet (C3 and later).

Tests: `worker/jobs/test/pr-record-intake.bh-8151.test.js`,
`tests/pr-record-webhook.bh-8151-test.sh`.
