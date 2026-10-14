# Lead review promotion lane, and the box-file verdict retired (BH-1951, BH-1525.3)

Doc: MERGE-CONDUCTOR

## What changed

- **`bin/lead-review-land.sh`, a new hub lane** (`cron/lanes/715-lead-review-land.cron`,
  `*/5`, gated on `bin/hub-lease.sh check`, registered in
  `catalog/lanes.d/lead-review-land.json`). It makes no agent call and no SSH.
  One `GET /api/lead-reviews?status=done,failed,requested,running&promoted=0`
  per tick. For each `done` request with a verdict and no
  `promoted_verdict_at`, it checks `/api/verdicts` for a `source=lead` row on
  that head whose note carries `lead-review:<id>`. If there is none, it runs
  `bin/lead-verdict.sh post … --source lead --reviewer box:<hub>`, then stamps
  `POST /api/lead-reviews/<id>/promoted`. A lost stamp is re-stamped on the
  next tick without a second row. The row is bound to the head the review
  read. A `failed` request, or one still `requested`/`running`
  `LEAD_REVIEW_OVERDUE_MIN` (default 120) minutes after `created_at`, gets ONE
  ALERTS line, deduped by `state/lead-review-land/alerted-<id>`. A truncated
  list and a missing lead token file each give one ALERTS line per UTC day.
  Log: `logs/lead-review-land.log`. Off: `flags/lane-off-lead-review-land`.
- **`GET /api/lead-reviews` takes `promoted=0`** (worker/jobs). It keeps only
  rows with no `promoted_verdict_at`, so the 100-row oldest-first list is
  never filled by requests already promoted. Any other value is a 400. An
  older worker ignores the parameter, and the lane re-filters client-side.
- **`bin/review-autopilot.sh` POSTs a `source=box` verdict row** (`ap_box_row`,
  box bearer only) right before each `reviewed …` key write: the first post,
  the promote-without-posting retry, and the BH-2310 replay. A failed POST
  leaves the key `status=reviewed-unposted` (tries+1, `.body` kept), so the
  next tick finds its own marker on the PR and retries the row with no model
  call and no second comment. A failed replay row writes no key, so the next
  tick replays again for free. "Not configured" writes the key as before and
  logs why: no jobs client, an empty `JOBS_URL`, the worker's own
  unknown-endpoint 404, or an `UNPARSED` verdict.
- **`bin/lib/verdicts.sh` gains `vd_box_word`**, the newest `source=box` row on
  the exact head, with `vd_standing`'s rc contract (the GET and its 404
  judgement are one private `_vd_get` now). A box row still never stands, so
  `vd_block_line` never answers from one.
- **`mc_autopilot_verdict` no longer reads `state/review-autopilot/*`.** The
  order is `vd_clear_word` (a lead/human MERGE standing), then `vd_box_word`,
  then the PR comment read as before. A box BLOCK still prints BLOCK, so the
  conductor still parks it for `bin/blocked-resolver.sh`.

## What it supersedes in MERGE-CONDUCTOR

"WHERE THE AUTOPILOT VERDICT IS READ" (BH-764) and the verdict-rows paragraph
(BH-1525) both describe `state/review-autopilot/<owner-repo>-<num>-<head12>` as
the conductor's first, free read and as the fallback. Neither is true now. The
file is the autopilot's own dedupe ledger (BH-1018) and nothing else reads it.
The `provcleared` line in `state/merge-conductor/attempts.txt` STAYS as
`mc_prov_cleared`'s fallback.

## For the Mac

The Mac's `land.sh` (lead tooling, not in this repo) still writes
`state/review-autopilot/…` over SSH. Those writes are now inert: no merge lane
reads them. A lead verdict goes in as a row: `bin/lead-verdict.sh post
<owner/repo> <pr> <head-sha> <MERGE|MERGE-WITH-NOTES|BLOCK>`, or ask for a
review with `bin/harness-ctl.sh review <owner/repo> <pr> <head-sha>` and let
this lane promote the answer.

## Tests

`tests/lead-review-land.bh-1951-test.sh`, `tests/verdict-files-retired.bh-1951-test.sh`
and `worker/jobs/test/lead-reviews-unpromoted.bh-1951.test.js`. Five existing suites
pinned the retired file read and were changed to the new spec, each marked
`TEST-CHANGE (BH-1951)`: `tests/lead-verdicts.bh-1525-test.sh`,
`tests/merge-conductor-deadend-test.sh` (sections 1-4 now set the autopilot
verdict up as a box row), `tests/review-autopilot.bh-1066-test.sh`,
`tests/review-autopilot-post-retry-test.sh` and
`tests/review-autopilot-replay.bh-2310-test.sh`.
