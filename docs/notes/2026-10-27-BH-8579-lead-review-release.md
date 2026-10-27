# A failed lead-review job releases its request (BH-8579)

## The incident

On 2026-10-27, three project-6-os lead reviews (#2797, #2799, #2812) stayed
`running` after their Fly pool jobs ended `failed`. The last heartbeats were
at 07:31Z-07:40Z. The reclaim sweep (BH-5779) read only the request's own
heartbeat, and its deadline was 3600 s (`lead_review_running_deadline_s`).
A person reset all three with `bin/lead-verdict.sh reset` at 08:15Z.

## The rule

`POST /api/lead-reviews/reclaim-stale` (`worker/jobs/src/lib/lead-review-release.js`)
releases a `running` row when:

1. Its bound job ended `failed` (or `abandoned` / `budget_stopped`, see below) more than one
   beat interval (`lead_review_claim_stale_s` / 3) ago, and no request
   heartbeat arrived after the job ended. Reason `job-failed`, detail
   `job failed: job <j> ended <status> at stage <stage> on <box> at <ts>; no heartbeat since <beat>`.
2. Or it went `lead_review.stale_running_min` minutes with no heartbeat.
   Reason `stale`, detail `stale: running with no heartbeat since <ts> (job <j>, box <b>); ...`.

A job that ended `abandoned` or `budget_stopped` is terminal (`core.js`: a
budget stop is never retried; abandoned is an operator's final call). Its row
goes straight to `failed` on either path, reason `job-terminal`, detail
`job terminal: job <j> ended <status> ...; not requeued`. The box writes one
lane-alert `lead-release-terminal-<id>`, and `lg_gate_retry` never resets it
(`[skip job-terminal]`, rc 10). A person decides the next review.

Before a requeue, the sweep reads the worker's `pr_records` fact. A `state` or
`head_sha` field stamped after the request was created that says closed or
merged, or another head, sets the row `superseded` (reasons `pr-closed`,
`head-moved`). No counter moves.

Else the row goes back to `requested` (reset recorded, queue position kept)
while `stale_reclaims` < `lead_review.release_max_resets`. At the cap it goes
to `failed`, and the box writes one lane-alert `lead-release-cap-<id>`. The
failed rung (`lg_gate_retry`) holds that row for
`LEAD_REVIEW_RELEASE_COOLDOWN_MIN`, then resets it under
`LEAD_REVIEW_FAILED_RETRY_MAX`.

The release runs in the worker sweep that every lead-review tick calls, so it
covers every placement (box, review-2, Fly pool). The worst case is
`stale_running_min` plus one tick.

## The knobs

| Knob | Where | Default | Meaning |
|---|---|---|---|
| `lead_review.stale_running_min` | settings row | 15 | minutes with no heartbeat before a reset; wins over `lead_review_running_deadline_s`; floored at `lead_review_claim_stale_s` |
| `lead_review.release_max_resets` | settings row | 3 | releases per row before `failed`; 0 = the first event fails |
| `LEAD_REVIEW_RELEASE_COOLDOWN_MIN` | lead-review lane knob | 15 | minutes a cap-failed row waits before the failed rung resets it; 0 = off |

## The acceptance query

No row may show here for 7 days:

```sql
SELECT r.id, r.repo, r.pr, r.job_id, COALESCE(r.heartbeat_at, r.updated_at) AS last_beat
  FROM lead_review_requests r
 WHERE r.status = 'running'
   AND COALESCE(r.heartbeat_at, r.updated_at) <
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (COALESCE((SELECT CAST(value AS INTEGER) FROM settings WHERE key='lead_review.stale_running_min'), 15) + 5) || ' minutes');
```
