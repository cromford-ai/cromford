# An empty lead BLOCK report is inconclusive; `lead-verdict.sh retract` (BH-8476)

Doc: LEAD-REVIEW

## What happened

`bin/lead-review-land.sh` posted a lead BLOCK as a verdict row first and read its report
second. When the report had no `- [BLOCK` line (BH-6090's check), the lane withheld the
REQUEST_CHANGES review, but the row already stood and `lead-verdict=failure` was already on
the head. Nobody could read or fix that BLOCK. #8278 (row #4057) and #8372 (row #4150) were
held for 20 and 14 hours.

## What changed

1. Step 1c of the land lane (`lrl_report_fetch`, `lrl_report_empty`, `lrl_inconclusive`).
   Before it posts a BLOCK row, the lane reads the report with the same rule step 2b uses.
   - Unreadable report: no row, no stamp. The next tick tries again.
   - This head's whole report with no line that starts `- [BLOCK`: INCONCLUSIVE. The lane
     writes no row and no status.
     1. It writes the first `LEAD_REVIEW_EMPTY_CAPTURE_BYTES` bytes (default 400, 0 = off)
        to `logs/lead-review-empty/<request-id>.txt`.
     2. If the PR left the head, it stamps the request and requests nothing.
     3. If no `lead_empty_block` ledger row keyed `<owner/name>#<pr>@<head>` exists (the
        jobs worker's `ledgers` table), it resets the request
        (`POST /api/lead-reviews/<id>/reset`), then writes that row (status `rerequested`).
        An unreadable ledger resets nothing, and the next tick tries again.
        The log line is `lead-review: empty BLOCK on <repo>#<n> @<head12>: no verdict
        recorded, re-requested`. The request is not stamped. A refused reset writes no
        row, and the next tick tries again.
     4. If the row exists, the log line ends `already re-requested once for this head`,
        and the request is stamped.
     Both 3 and 4 write the `emptyblock-<id>` ALERTS line (once per reset).
   - A truncated report, the `Full report:` pointer, or a report of another head is not
     provably empty. It posts as before. So does every MERGE and MERGE-WITH-NOTES.
2. At the end of each tick the lane deletes captures older than
   `LEAD_REVIEW_EMPTY_KEEP_DAYS` (default 30). The `lead_empty_block` ledger rows (a few a
   month) are kept by the ledgers' own policy; no state/ file is written (BH-4159).
3. `bin/lead-verdict.sh retract <verdict-id> --reason empty-report` (lead token) calls the
   new worker route `POST /api/verdicts/<id>/retract`. The verdicts table is append-only, so
   the worker stores a row in the new D1 table `verdict_retractions` (key `verdict_id`).
   Only a `source=lead`, `verdict=BLOCK` row can be retracted (409 otherwise).
   A repeat answers `existing:true`.
   The CLI then reads the head's standing row and republishes `lead-verdict`: failure for a
   BLOCK, success for a MERGE or MERGE-WITH-NOTES, pending when no row stands or when the
   lead row left is withheld for a human verdict (`authority:human-required`). It exits 4
   when the status is not published.
4. `GET /api/verdicts`: `standing` skips a retracted row. History rows carry
   `retracted_at` and `retract_reason`. `lrl_have` in the land lane skips a retracted
   row, so the next landing on that head treats it as absent. `lead-verdict.sh show`
   prints `retracted:<reason>` on such a row. The lead-word history readers also skip
   it: the BH-3930 rebound replay (gate 50 and `lead-review-enqueue.sh`), the builder
   carry, `lw_replay` and `lre_row_go`. So a retracted BLOCK is never replayed onto the
   next rebound head.
5. `vs_publish` (`bin/lib/verdict-status.sh`) accepts the state `pending`.
6. The BH-6090 alert for a row an earlier tick recorded now names the fix:
   `bin/lead-verdict.sh retract <row> --reason empty-report`.

## Operator step

After the worker deploys, run on the hub:

```
bin/lead-verdict.sh retract 4057 --reason empty-report
bin/lead-verdict.sh retract 4150 --reason empty-report
```

## Not changed

Why the model answers BLOCK with no finding. The capture in `logs/lead-review-empty/` is the
input for that ticket. `block-findings`, `review-tiers`, `lessons` and the daily digest still
count a retracted row in their history numbers.

Tests: `tests/lead-land-empty-block.bh-8476-test.sh`,
`worker/jobs/test/verdict-retract.bh-8476.test.js`.
