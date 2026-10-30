# BH-8651: release a crashed `claimed` PM brief row after a timeout

## What changed

`POST /api/pm/briefs/claim` (worker/jobs/src/routes/pm-brief.js) has a new path.
Before, a `claimed` row was final for its week, and only `--force` claimed it again.
Now a request with no `force` gets a `claimed` row back when the row's
`updated_at` is MORE than the timeout old. The answer is `{brief, claimed: true, released: true}`.

- Timeout: settings `lane.pm-groom.<project>.pm_claim_timeout_min` wins, then
  `lane.pm-groom.pm_claim_timeout_min` (seed 120, schema.d
  `202610301846-bh-8651-pm-claim-timeout.sql`), then the code fallback 120.
  `0` is off. A value that is not 0 and not an integer in 30..10080 goes to the next source.
  Catalog fragment: `catalog/lanes.d/pm-groom.knobs.d/PM_CLAIM_TIMEOUT_MIN.json`.
- The release is ONE D1 batch. First a CAS UPDATE on the `updated_at` the caller read,
  so of two racing callers one wins. Then one `stage_events` row
  (`stage=pm-groom`, `verdict=CLAIM_RELEASED`, `job_id=pm-brief:<project>:<week>`,
  detail `{brief_id, project, week, prior_updated_at, prior_input_fp, prior_model,
  timeout_min}`), written only when the CAS changed the row. Last, the read-back.
- Every claim answer now has `released`. `bin/pm-groom.sh` reads only
  `.claimed`, so after a release it goes on to its one call.

## What did not change

`force`, the `failed` and `ready` rows, and the create, fail, sent, GET and
decide routes stay as they were. The console did not change. The audit rows use
the `stage_events.closed` retention rule that already exists.

## Known gap

A crashed run can make a paid call and then lose its create POST. That run
keeps the answer in `failed-create.json`. After the timeout, a manual rerun pays
for one more call and does not use the kept answer.
