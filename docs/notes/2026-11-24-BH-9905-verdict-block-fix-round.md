# BH-9905 (C0): a standing BLOCK verdict row starts a fix round

Doc: MERGE-CONDUCTOR

## Cause

A human or lead BLOCK verdict row stops every merge lane on its head. Only a
GitHub review in state CHANGES_REQUESTED made a fix-round candidate
(`br_from_reviews`). On example-org/project-3, 2026-11-22, PRs #1286, #1295, #1249
and #1246 had a human BLOCK row with the fix in `--note` (verdicts #6214 to
#6219) and no fix round for 3 hours. #1249 had only the review autopilot's box
BLOCK row (#6126) and sat for 2 days, outside `BR_REVIEW_LOOKBACK_SECS`.

## Change

- `bin/blocked-resolver.d/bh-9905-verdict-block.sh` (new). `bvb_candidates` is
  one more candidate source, called from `_br_sources` after `br_from_reviews`.
  Per project and tick it makes ONE batch read of BLOCK rows
  (`vd_repo_blocks`). It matches the rows to the open-PR list's live heads, and
  confirms only the matched PRs with `vd_standing_note` / `vd_box_word`:
  - a lead/human BLOCK standing on the live head (no `[BLOCK needs-human]` in
    the note) is source `verdict-block`;
  - with nothing standing, a box BLOCK row plus the newest harness
    `harness-review-autopilot` comment for that head with a `[BLOCK <class>]`
    finding (not needs-human or console-qa) is source `autopilot-block`,
    unless the conductor already parks the head as `review-block:` (BH-9260).
  The row carries reason `review-changes-requested` and the rkey and ticket key
  `br_from_reviews` derives. So the one round per (PR, head), TICK_DONE, the
  review cap and `br_fix_terminal` apply unchanged, and a CHANGES_REQUESTED
  review plus a BLOCK row on one head are one round. The age of the PR does not
  matter here; `BR_REVIEW_LOOKBACK_SECS` still bounds reviews only. Log line:
  `<p>/<rkey> [verdict-block/review-changes-requested] -> fix-round`.
- `bvb_brief` (one line in `br_fix_round`, review reason only) adds the BLOCK
  row's note under `BR_LEAD_HDR` with the body of the comment or review it
  links to on the same PR, or the autopilot comment. Another URL stays text.
- `bin/lib/verdicts.sh`: `vd_repo_blocks` (the batch read) and
  `vd_standing_note` (the standing row with its note). `_vd_route_missing`
  names the route that is missing.
- `worker/jobs/src/routes/verdict-blocks.js` (new): `GET /api/verdict-blocks`,
  with the index `idx_verdicts_repo_verdict_created` and the settings row
  `verdict_blocks.max_rows` (1000) in
  `worker/jobs/schema.d/202611242327-bh-9905-verdict-blocks.sql`. EXPLAIN
  QUERY PLAN at 20,000 seeded rows: `SEARCH verdicts USING INDEX
  idx_verdicts_repo_verdict_created (repo=? AND verdict=? AND created_at>?)`.
- `bin/lib/fix-round-offer.sh` (new) and `bin/lead-verdict.sh` `lv_post`: a
  BLOCK with `--source human|lead` prints one stderr line, `lead-verdict: fix
  round: will be offered on the next blocked-resolver tick`, or the first reason
  it will not (`blocked-resolver-disabled`, `automerge-disabled`, the lane off,
  `BR_VERDICT_BLOCK` 0, a round already ran on the head, the cap spent). Stdout
  and exit codes do not change.
- Knobs: `BR_VERDICT_BLOCK` (1), `BR_VERDICT_BLOCK_LOOKBACK_DAYS` (30),
  `BR_VERDICT_BLOCK_LIMIT` (500), in `catalog/lanes.d/blocked-resolver.knobs.d/`.

The lane writes and retracts no verdict row. Slice C1 adds the console state
(fix round queued / in flight / spent).

## Tests

`tests/blocked-resolver-verdict-block.bh-9905-test.sh`,
`tests/lead-verdict-fix-offer.bh-9905-test.sh`,
`worker/jobs/test/verdict-blocks.bh-9905.test.js`.
