# BH-9823: one review verdict per head; no queue while a lead review of that head is pending

Doc: MERGE-CONDUCTOR

## Cause

On PR #9811 (2026-11-18) the conductor and the lead lane each reviewed the same
head, twice. The chain:

1. `headbound_review` (`bin/lib/mc/classify.sh`, `*)` arm, mode `moved`)
   consumed the >12h autopilot MERGE on a HEAD_MOVED head with green CI. It
   called `hb_approve_bind`, which posted the "approval rebound" comment.
2. `hb_approve_bind` called `job_verdict_rebind`, which moved the builder
   APPROVE's `reviewed_sha` onto the new head. The row went READY and the
   conductor enqueued it.
3. `bin/pr-state-reconcile.sh` then set `builder_approved_sha=<head>`, so
   `needsReviewRows` (`worker/jobs/src/lib/pr-gate.js`) put the head on the
   lead lane's worklist.
4. Gate 10 (`bin/lib/lead-gates.d/10-builder.sh`) passed it. No gate read the
   head's autopilot (box) row. The lead lane bought a second review.
5. The lead BLOCK stood on the head. The block gate refused it and the PR left
   the queue: 2 cycles, 0 CI runs, 11 minutes each.

Two defects: nothing stopped the lead lane from starting on a head the
autopilot had verdicted, and nothing stopped the conductor from rebinding or
enqueuing while a lead review of that head was in progress.

## What changed

- Rule 1a and rule 2, the conductor (`bin/merge-conductor.d/bh-9823-one-verdict.sh`).
  A pending lead review is a `lead_review_requests` row on this exact head with
  status `requested` or `running` (one GET `/api/lead-reviews?repo&pr&status`).
  - HEAD_MOVED (`mc_ovh_moved_hold`, before `headbound_review`): the row stays
    HEAD_MOVED with the why `WAIT_LEAD_REVIEW <h8> ...`. No autopilot consume,
    no rebind, no comment, no re-review bought.
  - READY (`mc_ovh_ready_hold`, after `mc_lead_req_hold`): the row is
    WAIT_LEAD. No queue call.
  - When the request ends on a head the conductor waited on, the lead verdict
    is the verdict of record. A lead or human MERGE rebinds the approval with a
    comment that names the lead review. A lead or human BLOCK parks the row
    `head-not-reapproved` for `bin/blocked-resolver.sh`. A request that ended
    with no verdict takes today's path.
- Rule 1b, the lead lane (`bin/lib/lead-gates.d/12-autopilot-bound.sh`). On a
  repo that does not require a lead MERGE, a worklist head whose newest box row
  is MERGE or MERGE-WITH-NOTES gets `[skip autopilot-bound]` (rc 10). A box
  BLOCK is not bound: a box row never stands, and on a READY head nothing reads
  it, so the lead still reviews that head. A lead_required repo is not gated: it
  merges only on a lead MERGE.
- Log field: every queue decision line carries `review_source=<word>`
  (`lead`, `human`, `autopilot`, `autopilot-after-lead-limit`, `bound`,
  `conductor-rereview`, `builder`, `lead-pending`; `+lead-unread` when the
  request list could not be read). The field is at the END of the enqueue line,
  so every grep for `enqueued in the <provider> merge queue at <h8>` still
  matches.

## The knob

`MC_LEAD_REVIEW_WAIT_S` (default 2700 s, settings row
`lane.merge-conductor.mc_lead_review_wait_s`). Past it: one
`LEAD_REVIEW_OVERDUE` warn alert per (PR, head) (attempts mark `ovhlimit`,
written before the alert), then the autopilot verdict is used. 0 = no wait,
the behavior before BH-9823. 2700 is `MC_REREVIEW_TIMEOUT_SECS`, and below
`MC_BUDGET_WAIT_LEAD` (3600), so no stuck page fires before the limit.

## Fail-open reads

An unreadable request list is today's path, with one log line per (PR, head)
(mark `ovhunread`). A hold would stop every enqueue of the fleet on a jobs
worker outage. An unreadable verdicts read after a wait is today's path too.
The block gate is unchanged and still refuses a lead BLOCK that lands after an
enqueue.

## Kept

A head with no pending lead review takes today's path byte for byte: the
autopilot consume, the re-review purchase, the enqueue.

Suite: `tests/mc-one-verdict-per-head.bh-9823-test.sh`.
