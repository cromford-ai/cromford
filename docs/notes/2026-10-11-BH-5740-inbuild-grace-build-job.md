# The in-build grace holds a medium head only while a build job is live on it (BH-5740)

Doc: MERGE-CONDUCTOR

## What changed

- `bin/lead-review-enqueue.sh` held every medium head under `enforce` for
  `risk_tier.inbuild_grace_s` (fallback 3600 s) before it requested a lead
  review (BH-5023). Since BH-5630 the lane also requests heads that no build
  reviewed: pushes from the Mac or a person, main merges and conflict fixes.
  No in-build review comes for those heads, so each one waited the full hour.
- Before it holds a head, the lane now reads the PR's ledger job with one
  `GET /api/verdict?pr=<url>` (`inbuild_job_on_head`). The grace holds only
  when `.job.kind` is `build`, `.job.status` is `running`, `queued`,
  `queued_for_retry` or `claimed`, and `.reviewed_sha` is the PR head. A
  provisional verdict row counts: that build still runs the in-build review.
- With no such job, the lane requests the head in the same tick, the same as a
  low or high head. It writes no marker and one log line:
  `inbuild-grace skipped #<n> head=<sha12>: no build job for this head (<slug>; <why>)`.
  `<why>` is one of: no job recorded the PR, the PR job is not a build, the
  build job is in a finished status, or the build job is bound to another head.
- If the job read fails (worker outage, unparseable answer), the grace holds as
  before and the lane logs `<why>; the in-build grace holds as before`.
- A grace of 0 holds nothing, as before, and now reads no job.

This corrects the "What re-runs it" paragraph of
[2026-10-07-BH-5023-inbuild-lead-review.md](2026-10-07-BH-5023-inbuild-lead-review.md):
a push from another lane no longer waits out the grace. It is requested at once.

## Check it

    grep 'inbuild-grace skipped' /root/harness/logs/lead-review-enqueue.log

Suite: `tests/inbuild-grace-outside-push.bh-5740-test.sh`.

## Follow-up

PR #6035 (BH-5875) ports the grace to `bin/lib/lead-gates.d/70-inbuild-grace.sh`
for the worklist dispatcher. That file is not on main. The same rule must reach
that gate when #6035 lands.
