# Cost rows keep lane_id and guard_fp from the emitter (BH-3220)

Doc: COST

## What changed

- `_cost_row_emit_body` (`bin/lib/cost-row.sh`) posts all 26 `COST_ROW_HDR`
  columns. Its list stopped at `note`, so the row posted the moment a call
  finished carried no `lane_id` / `guard_fp`, landed first, and the */10
  mirror's full row lost the `(box, row_hash)` race.
  `tests/cost-row-emit-cols-parity.bh-3220-test.sh` fails if the emitter's list,
  the mirror's (`_metric_cost_rows_chunk`) and `COST_ROW_HDR` ever differ.
- `POST /api/metrics/cost-rows` no longer answers a conflict with `DO NOTHING`.
  It fills a NULL `lane_id` / `guard_fp` from the incoming row, and only when
  there is something to fill. A set value is never overwritten, an incoming NULL
  never blanks one, and no other column changes. `inserted` counts new rows and
  repaired rows. A byte-identical re-push still answers `inserted: 0`, so the
  dup count `bin/cost-rows-push.sh` reads keeps its meaning.
- `bin/cost-rows-lane-backfill.sh` is a one-shot for the rows already in D1. It
  reads `GET /api/metrics/cost-rows` since `--since` (default
  2026-09-25T00:00:00Z), takes rows with a NULL `lane_id` / `guard_fp` whose
  `raw` hashes to their `row_hash` and has at least 25 fields, and re-POSTs them
  with fields 25 and 26. It is a dry-run by default; `--apply` sends.

## Why

Per-lane caps (`/api/metrics/llm-spend?lane=`) count `lane_id IS NULL` rows
against every lane on a stage, and lane-dedup, LLM Sites and the BH-2537
fingerprint readers all read these columns. On 2026-09-28, 39 of 1,014 D1 rows
carried `lane_id` while the boxes' `cost.csv` had it on every row.

## Operator step after the worker deploys

On the hub: `bin/cost-rows-lane-backfill.sh` (read the count), then
`bin/cost-rows-lane-backfill.sh --apply`. It must run after the deploy: against
an older worker it reports `repaired 0` and exits 1.
