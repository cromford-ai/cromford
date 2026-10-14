# Cost rows gain guard_fp, column 26 (BH-2537 slice 1, BH-2665)

Doc: llm-choke-point

## What changed

- **`logs/cost.csv` has 26 columns.** `COST_ROW_HDR` in `bin/lib/cost-row.sh`
  ends `lane_id,guard_fp`. `guard_fp` is the pre-call guard's input
  fingerprint (K3), read from `$COST_GUARD_FP` by the new
  `cost_row_guard_fp`. No writer sets it in this slice, so every row written
  today is still 25 fields and reads `guard_fp` empty under the new header.
- **The header upgrade has a `25)` arm.** A box whose file has the 25-name
  header gets `,guard_fp` appended to line 1 on its next `cost_append`. Older
  generations (13/14/16/23/24) now upgrade straight to 26. Data rows are never
  rewritten.
- **Tag fallbacks.** `cost_row_tags` takes the ticket from `COST_KEY`, then
  `AGENT_CALL_TICKET`, then `HARNESS_TICKET`, and the pr from `COST_PR`, then
  `AGENT_CALL_PR`.
- **Transport and storage.** The push (`_metric_cost_rows_chunk` in
  `bin/lib/jobs/cost.sh`) sends `guard_fp` (null for a 25-field row).
  `cost_rows.guard_fp TEXT` is in `worker/jobs/schema.sql` for a fresh
  database and in `ADDED_COLUMNS` so `ensureColumns` adds it to the live one.
  It is not indexed, for the same reason `lane_id` is not.
- **The two reader header copies** (`COST_ROWS_READ_HDR`'s fallback and the
  `fleet-cost.csv` header in `bin/cost-rollup.sh`) end `,guard_fp`.
- **`GET /api/metrics/cost-rows`** filters on `guard_fp` and `lane_id` (exact
  match; rows written before lane_id existed are not returned for
  `?lane_id=`).
- **`GET /api/metrics/lane-dedup?days=`** is a stub. It validates `days`
  (absent or empty is 7, otherwise an integer 1..30, anything else a 400 and
  never clamped) and answers `{days, lanes: [], truncated: {fps: false}}`. It
  reads no rows. The aggregation lands with #2669.

## Rollout order

A box can sync before the worker deploys. The old worker ignores the unknown
`guard_fp` key, so the D1 column stays NULL for those rows while `raw` still
carries the verbatim line. There is no backfill of old rows.

`bin/agent-call.sh`'s own fallback header and the llm-gate refused row stay at
25 columns; the agent-call writer sibling (#2666) changes them.
