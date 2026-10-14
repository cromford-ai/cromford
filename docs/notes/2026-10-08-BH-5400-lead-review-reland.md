# A reset lead review lands its new verdict (BH-5400)

Doc: LEAD-REVIEW

## What changed

`bin/lead-review-land.sh` used to treat a request id it had already landed as
done. On 2026-10-07/08, 15 false BLOCKs were landed, their requests were reset
to `requested` with raw SQL, and the re-reviews finished (mostly MERGE). The
lane found the old `lead-review:<id>` row and only stamped, so GitHub kept the
false BLOCKs until the orchestrator re-posted and dismissed by hand.

Now "already landed" is keyed on (request id, job id). Every review run claims
with a new job, so the job names one result:

- row note `lead-review:<id> lead-job:<job>` (+ `supersedes:<rowid>` on a
  re-land); findings review line 2 `<!-- lead-job:<job> -->`; the per-request
  flags in `state/lead-review-land/` hold the job;
- a newer result posts a new row and status; MERGE dismisses the earlier
  landing's CHANGES_REQUESTED on the same head; BLOCK posts the new findings
  first, then dismisses the earlier landing's review;
- the promoted stamp sends `{"job_id":<job>}` and the worker refuses it (409)
  when the request now holds another job.

The worker records resets: `lead_review_requests.reset_count` / `reset_at`
(ADDED_COLUMNS, applied by ensureColumns). `POST /api/lead-reviews/<id>/reset`
and `bin/lead-verdict.sh reset <request-id>` are the sanctioned path. The claim
route records a raw-SQL reset too and clears the stale promoted stamp, so the
new result is listed by `?promoted=0` again.

## Not covered

A PR opened by `cromford[bot]` (the lane's own identity) still gets a
re-landed BLOCK as a COMMENT, because GitHub refuses REQUEST_CHANGES from a PR's
author. That needs an identity or policy decision and is a follow-up.

A raw reset that nulls the job, verdict and promoted stamp of a row landed
before this change looks like a fresh row. Use the CLI.

## Where

`docs/verification-map/lead-review-land.md` ("Re-landing after a reset"),
`tests/lead-review-land-reland.bh-5400-test.sh`,
`worker/jobs/test/lead-reviews-reset.bh-5400.test.js`.
