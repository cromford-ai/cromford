# Lead reviews no longer get stuck on a failed request, a silent skip or a stale running row (BH-5779)

Doc: OPERATING, worker/jobs/README.md

## Why

On 2026-10-09 six PRs waited 5 hours to 2 days for a lead review that was not
running. A Mac session requested or reset each one by hand. The evidence, read
from `GET /api/verdict?pr=`, `GET /api/verdicts?repo=&pr=` and `gh pr view`:

| PR | author | live head | builder `job_verdict` | what the enqueue did |
|---|---|---|---|---|
| #3991 | operator | e242fb55b | REQUEST_CHANGES on e242fb55b | skipped as no-approve, no log line |
| #5302 | operator | aeac40252 | REQUEST_CHANGES on aeac40252 | the same silent skip |
| #5258 | operator | c0b291b1f | REQUEST_CHANGES on c0b291b1f | the same silent skip |
| #5199 | builders | 72b69292f | APPROVE on f828d4194 | the request for the head was `failed`; the POST answered `existing:true` and was counted as existing |
| #5735 | builders | 86ad2af78 | APPROVE on 86ad2af78 | the same path as #5199 |

#5282, #5308 and #5460 showed `running` since 09-28 or 10-08 with no live
claim. Nothing sent such a row back by itself.

## What changed

- `bin/lead-review-enqueue.sh` reads the status of an existing request. A
  `failed` row for the current head is reset through
  `POST /api/lead-reviews/<id>/reset`, at most `LEAD_REVIEW_FAILED_RETRY_MAX`
  times (lane knob, default 2). The resets this lane made are counted in
  `state/lead-review-enqueue/failed-retry.tsv`, keyed on repo, PR and full
  head sha. A hand reset does not use the budget. When the budget is used, the
  next failure sends one alert, `lead-failed-<slug>-<n>-<sha12>`, that names
  the failure reason. A reset counts toward `LEAD_REVIEW_ENQUEUE_MAX_PER_TICK`
  and the 24 h tripwire. An ENVIRONMENT failure (exactly `checkout`,
  `no-checkout` or `empty`, or a `review-failed: env:` prefix, the land lane's
  own `case`) is left to `bin/lead-review-land.sh` only while that lane owns it:
  #5809 (BH-5793) registers `LEAD_REVIEW_ENV_RETRY_MAX` in
  `catalog/lanes.d/lead-review-land.json` and requeues those failures. Then the
  enqueue writes one `[skip env-failed]` line and leaves it. Without that
  registration (main before #5809) nothing else requeues them, so the rung
  resets them here like any failure, within the same budget. The rung owns
  the rest, for example a row the worker failed as `stale` (below).
- Every `continue` in the per-PR loop writes one line with the PR, the head
  and the reason, ending in ` [skip <class>]`. Lines that existed before keep
  their bytes; only the suffix is new. A lead-authored PR that the builder
  sent back names the author and the `bin/lead-verdict.sh request` command.
  A worker `detail` is redacted (`://user:token@` and `gh?_` tokens) before
  it reaches a log or an alert.
- Each tick posts `POST /api/lead-reviews/reclaim-stale` once. An error or a
  404 from an older worker writes one line, and the tick goes on. The summary
  line adds `failed_reset=`, `failed_alerted=` and `reclaimed=`.
- The worker route `POST /api/lead-reviews/reclaim-stale` (lead token) takes a
  `running` row whose `heartbeat_at` (else `updated_at`) is older than settings
  `lead_review_running_deadline_s` (seed 3600, code fallback 3600, floored at
  `lead_review_claim_stale_s`). The first time, the row goes back to
  `requested` and its `job_id` is cleared, so the old job's `/result` and
  `/heartbeat` answer 409. The second time, the row goes to `failed` with
  detail `stale: …`, and the retry budget above owns it. The new nullable
  column `stale_reclaims` counts this.
- Not built here: ticket item 2 (a `checkout` failure that is a merge
  conflict becomes "needs rebase"). The Mac takeover dropped the pool's draft
  of it, because #5809 already requeues a `checkout` failure and changes the
  same lines of `bin/lead-review.sh`. A follow-up can mark the conflict case on
  top of #5809.

## Assumptions

- A1. The retry budget counts only the resets this lane made, not the
  worker's `reset_count`, which also counts hand resets.
- A2. "Needs rebase" is recorded as `outcome=superseded` on the lead row. No
  new label or marker file is added.
- A3. A row is reclaimed to `requested` once. A second stale run goes to
  `failed`, so the reclaim is bounded.
- A4. A lead-authored PR that passes the builder gate is already requested. A
  lead-authored PR the builder sent back is still skipped, and its line names
  the author and the command to ask by hand.
- A5. An environment failure (including `empty`) is #5809's land lane's to
  requeue once #5809 is on the tree (it registers `LEAD_REVIEW_ENV_RETRY_MAX`).
  Until then the enqueue resets it within the same budget (lead review of
  abc4e89a).

## Operator facts

- Log volume: one skip line for each (PR, head, skip class). A repeat on a
  later tick is counted in the summary (`skips=`) but not written
  (`skips_logged=`); a new head or a new class is written once more. Before
  this, every open PR wrote one line on every tick: about 29,000 lines a day
  at about 100 open PRs and a 5-minute tick. The rebase, traced and silence
  holds write their skip line the same way.
- `bin/harness-sync.sh` applies the settings seed from `worker/jobs/schema.sql` (generated from `worker/jobs/schema.d/0014-lead-review-deadline.sql`)
  before the worker deploy. The column is added by `ensureColumns`.
- `bin/lead-review-land.sh` is not changed here. Its `failed` alert still
  fires once for each reset of a failing head.
