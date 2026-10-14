# A lead-cleared head reaches the merge queue, and one that does not pages (BH-3778)

Doc: MERGE-CONDUCTOR, MERGIFY

## Why

On 2026-10-01 at about 14:00Z, ten cromford PRs had a lead-lane
MERGE-WITH-NOTES and a green `lead-verdict` status on their current head, and
none was in the merge queue. The lead enqueued them by hand. Nothing paged.

Seven of the ten were stacked on a parent's branch until about 14:02Z, and the
conductor holds a stacked PR in STACKED_WAIT on purpose. The gap this note
covers is narrower than the incident:

- The conductor reads READY only from the builder's own APPROVE bound to the
  head (`mc_verdict`). The BH-764 autopilot arm does consume a standing lead
  MERGE on a moved head, but only inside `headbound_review`, and only when no
  detached re-review job exists for that head. The conductor spawns that job as
  soon as a moved head goes green, so a lead MERGE that lands while it runs is
  not read. The PR sits in `HEAD_MOVED REREVIEWING` until the job ends, and
  the job can end in a park. Even when the arm does run, the enqueue waits a
  tick.
- pipeline-health section 12 skips any row that is not READY and reads only a
  builder APPROVE. Section 13c reads only a `dequeued` payload. No check
  looked at "lead-verdict success on the head, not in the queue".

## What changed

- `bin/lib/mc-lead-ready.sh` (new): `mc_lead_ready`. On a governed repo (one
  with a line in `catalog/lead-protected-paths.tsv`), a standing lead or human
  MERGE / MERGE-WITH-NOTES on the live head counts as APPROVE bound to that
  head, but only when `la_decide <repo> <pr> <head> conductor` answers rc 0.
  That means no protected path, and the lane is the authority. It never
  overrides a builder BLOCK, a CONTRADICTION or a headbound `blocked@<head>`.
  Every unreadable answer means no rebind. It logs one `LEAD_READY` line per
  (PR, head), deduped by the attempts line `leadready <key> <head>`.
- `bin/merge-conductor.sh` calls it right after the patch-id / overlap rebind,
  before the CI read and the classifier. Nothing downstream changed. The
  STACKED_WAIT park, the CI ladder, the block gate, the merge budget and
  `mc_enqueue_mergify` (with its per-head ask ledger) all still run, so the
  label and `@mergifyio queue` go out once per head.
- `bin/pipeline-health.sh` has a new block, `# >>> lead merge unqueued
  (BH-3778)`, section 13d. For each repo in `LEAD_REVIEW_AUTO_REPOS`, it pages
  `leadunqueued:<owner/repo>#<n>:<head12>` once per head (7-day TTL) for an
  open, non-draft PR based on the default branch that meets two conditions:
  its head's `lead-verdict` status has read `success` for at least
  `LEAD_MERGE_UNQUEUED_MIN` minutes, and it has no `queued` / `checking`
  label. Each run does one list read per repo and one status read per
  candidate, capped at 30 with a page-cut alert. `leadunqueued` is in
  `RETRACT_NS`, so a PR that gets queued or merged retracts its page. A
  skip is not a clear: when the GH budget gate skips the block, a
  lead-review-land knob fails closed, a repo's token or list read fails, a
  PR's status read fails, or a PR sits past the 30th, the block carries that
  scope's standing `leadunqueued:` keys into this run's fired set. The
  retraction epilogue only RESOLVEs a key a successful read found clean, so a
  transient read failure never posts a false RESOLVED or a second page for
  the same head.

## Knobs

- `MC_LEAD_READY` (merge-conductor, default 1). 0 turns the rebind off and
  restores the pre-BH-3778 behavior.
- `LEAD_MERGE_UNQUEUED_MIN` (pipeline-health, default 30, minutes).

## Unchanged

- A protected path, or a repo whose `lead_authority` row is `human`, gets no
  rebind. Its PR keeps waiting for a `--source human` verdict, as BH-3683 set
  up.
- lead-review-land, `mc_enqueue_mergify`, and the lead-PR fence (BH-1606).

## Limits

- The rebind sits before `mc_job_running`, which only guards the re-review
  purchase. A lead MERGE that lands while the PR's own builder review is still
  running (builder verdict `-`) is enqueued before the builder writes its
  verdict, so a builder BLOCK that arrives after that does not pull the PR
  back out through this path. "Never over a builder BLOCK" holds for a BLOCK
  already on the ledger, not one still being written. That matches BH-3683:
  for a non-protected path, the lane is the authority.
- The suite's C3 asserts that a protected path gets no rebind and no enqueue.
  It does not assert that lead-review-land's human-needed beat still fires;
  that code is unchanged by this ticket and
  `tests/lead-authority.bh-3683-test.sh` and
  `tests/lead-review-land-authority.bh-3683-test.sh` pin it.
- 13d measures age from the `lead-verdict` status's `updated_at`. A PR that
  was stacked for hours and then retargeted to main can page on its first
  tick after the retarget, even if the conductor enqueues it that same tick.
  Expect occasional noise on that shape. The page retracts once Mergify
  labels it.
