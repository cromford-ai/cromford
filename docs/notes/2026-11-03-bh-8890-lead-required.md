# A builder APPROVE alone never clears a lead-required repo (BH-8890)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

On 2026-11-01 the conductor put example-org/project-6 #3501 (TK-3499, head
f1c9c028) in the merge queue on the build's own review. No lead had reviewed
the head. The conductor also tried to publish `lead-verdict=success` on it.

- New settings row `lead_required.<owner>.<name>` (lowercase). The seed sets
  `lead_required.example-org.project-6` = `1`. No row reads as 0.
- `pr_worker` in `bin/merge-conductor.sh` calls `mc_lead_req_hold` directly
  after `mc_mig_hold`. The function is in the fragment
  `bin/merge-conductor.d/bh-8890-lead-required.sh`. The reads are in
  `bin/lib/lead-required.sh`. It acts only on a READY row of a repo whose row
  is 1:
  1. A lead or human MERGE / MERGE-WITH-NOTES stands on HEAD (`vd_standing`,
     with the `lead_carry` patch carry): the row stays READY. Log line
     `<key> LEAD_REQUIRED_OK on <h8>`, once per head.
  2. Nothing stands: the row is `WAIT_LEAD`, reason `WAIT_LEAD lead_required=1:
     builder <V> on <h8>, no lead or human MERGE on this head`. The conductor
     runs `bin/lead-verdict.sh request <slug> <pr> <head>` once per head
     (attempts mark `leadreq <key> <head>`, written before the ask). Log line
     `LEAD_REQUESTED` or `LEAD_REQUEST_FAILED rc=<n>`. A failed ask is not
     retried on that head. `bin/lead-review-enqueue.sh` stays the backstop.
  3. A lead BLOCK (or other word) stands: `WAIT_LEAD`, no ask.
  4. The row or the verdict cannot be read: `WAIT_LEAD` for this tick, no ask.
  5. Observe mode or the kill switch: `WAIT_LEAD`, a `WOULD request` line.
- `WAIT_LEAD` is a new conductor state. `MC_STATES`, the stuck-work and
  utilization state lists, and the worker's conductor-held state set know it.
  TTL `MC_TTL_WAIT_LEAD` (21600 s), budget `MC_BUDGET_WAIT_LEAD` (3600 s).
- The three conductor publishers of a clearance (`mc_enqueue_mergify`,
  `mc_rebind_publish`, `mc_vs_ttl_republish`) post under `LR_CTX`, set by
  `lr_clear_context`. On a repo whose row is 1, `LR_CTX` is `lead-verdict`
  only when a lead or human MERGE stands on the head. Else it is
  `harness-verdict`. On every other repo it is `lead-verdict` and no verdict
  is read, so the POST is the same as before. `bin/lib/merge-conductor-lib.sh`
  loads the lib, so the console Merge button and the other enqueue callers get
  the same context. `bin/lead-verdict.sh post` is unchanged.
- The batch train (`bin/batch-resolve.sh`) is a second automated landing path.
  `br_member_fenced` now also calls `br_lead_required_fenced`: on a repo whose
  row is 1, a member (a pool PR too) needs a lead or human MERGE /
  MERGE-WITH-NOTES on its exact head. Without one it is not a candidate, and a
  member whose lead row goes away after the train opened is ejected
  (`fence_eject`, `reform_train`). An unreadable row or verdict keeps the
  member out for that pass. Log line `#<n> MERGE_HELD lead-required on <h12>`,
  written on each pass. There is no say-once memo, so the lane keeps no new
  state file for it.
- Known gaps (C1): a PR that already carries the queue label before this
  change deploys stays QUEUED and never reaches the READY gate. On a repo whose
  row is 0, a failed settings read makes `lr_clear_context` read the verdict,
  so a builder-only publish can go out as `harness-verdict` in that window.
  `lead_required.*` is not a signed (protected) settings prefix yet.

## What is not in this change (slice C0 of #8890)

The ticket also asks that a builder-only status use the new name on a repo
whose row is 0. That is child slice C1. cromford's own queue
(`config/mergify/repos/cromford.conf`, `status_check=lead-verdict`)
requires `lead-verdict`, and its builder-cleared PRs enter the queue on the
conductor's publish. A rename here would hold every such PR in Mergify. C1
steps:

1. Publish `harness-verdict` next to `lead-verdict` on a builder-only clearance.
2. Probe it live on a cromford PR (BH-1000).
3. Switch cromford's queue condition to accept `harness-verdict`, and
   keep a lead BLOCK as a dequeue.
4. Stop the builder-only `lead-verdict` publish.

project-6's queue does not read `lead-verdict` today (its `.mergify.yml`
queue conditions are `#changes-requested-reviews-by=0`, `check-success=ci`,
`check-success=e2e-ratchet`). On project-6 the conductor gate is the lead gate.

## Operator steps

1. Require a lead verdict on a repo:
   `bin/jobs-client.sh setting-set lead_required.<owner>.<name> 1`.
2. Remove the requirement: set the row to `0`.
3. Check a held PR: `grep -E "WAIT_LEAD|LEAD_REQUESTED|LEAD_REQUIRED_OK" logs/merge-conductor.log`,
   then `GET /api/verdicts?repo=<slug>&pr=<n>` for the lead row that follows.
   The next tick after a lead MERGE is READY.

4. Read a held train member: `grep "MERGE_HELD lead-required" logs/batch-resolve.log`.

Tests: `tests/merge-conductor-lead-required.bh-8890-test.sh`. Cases B1-B5 are
the train: they run `br_member_fenced` and `br_lead_required_fenced` from the
shipped `bin/batch-resolve.sh` beside the real lib.
