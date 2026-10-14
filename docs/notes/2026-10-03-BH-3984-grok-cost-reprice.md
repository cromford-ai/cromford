# Grok rows record the fleet's price, not the vendor's ticks; a backfill for the history (BH-3984)

Doc: COST

## What changed

- `bin/agent-call.sh` (grok lane) prices the ledger's tokens with
  `cost_price_tokens` (`bin/lib/cost-row.sh`) and records that as `cost_usd`,
  ticks or no ticks. The vendor's `costUsdTicks` figure stays in `result_usd`.
  Before, a ledger that reported ticks set `cost_usd` to the ticks and the
  table was only read when they were absent. `cost_row_price` rule 1 ("a dollar
  figure on the row is final") then kept it.
- `bin/grok-envelope-probe.sh` does the same with the envelope: the table's
  price is `cost_usd`, `total_cost_usd` stays in `result_usd`.
- Only a model the price table cannot price keeps the vendor's figure as
  `cost_usd` (today's behavior for it). A box whose `bin/lib` has not synced
  has the `cost_price_tokens` stub, which prices nothing, so it writes the row
  it wrote before.
- New `bin/cost-reprice-backfill.sh`, one-off and human-run. It reads D1
  through `GET /api/metrics/cost-rows`, reprices grok rows and blank rows with
  tokens using the same `cost_price_tokens`, prints a summary, and with
  `--sql <file>` writes guarded `UPDATE`s. It never writes D1.

## The ledger, 2026-09-21 .. 2026-10-03 (read-only, this build)

`bin/cost-reprice-backfill.sh --since 2026-09-21T00:00:00Z`, rc 0:
- 19,079 rows scanned.
- 169 grok-4.6 triage rows took their dollars from the ticks: recorded
  $41.31. 418 other grok rows were already within $0.005 of their reprice
  (they were priced by the table).
- 41 rows with tokens and a blank `cost_usd`, all openrouter
  `deepseek/deepseek-v4-flash` on pool machines between 2026-09-21T00:04Z and
  2026-09-22T10:34Z (the price table those machines had then lacked the model;
  the catalog has it now and no such row has been written since).
- Repriced total over all 210 candidates: $772.87. 0 unpriceable.
- 1,136 blank rows have no tokens (failed calls: openrouter plan 588, grok
  triage 291, openrouter review 92 / execute 72, grok canary 25, codex triage
  22, ...). They stay blank.

The formula itself is out of scope here (a separate issue). Evidence for it:
on the largest vendor-priced row (input 8,051,080, cache_read 7,067,136,
output 78,236) the vendor said $1.99 and `cost_price_tokens` says $40.21. The
cliff is applied to a session total rather than per request, and if grok's
input count includes cached tokens then `cache_read` is counted twice.

## The human step

```
bin/cost-reprice-backfill.sh --since 2026-09-21T00:00:00Z --sql /tmp/bh3984.sql
cd worker/jobs && npx wrangler d1 execute harness-jobs --remote --file=/tmp/bh3984.sql
```

Each statement is guarded on `(box, row_hash)` and on the row's current
`cost_usd` (`IS NULL` for a blank row, `= <old>` for a grok row), so a
re-apply changes nothing. `raw` is left as the box wrote it, so a reader that
rebuilds from `raw` (`bin/lib/cost-rows-read.sh` into `bin/cost-rollup.sh`)
still sees the old grok figure for historic rows. Box-local `logs/cost.csv`
files are not rewritten.

Proof after the apply:
`SELECT runner, COUNT(*) n, SUM(cost_usd IS NULL) blank FROM cost_rows WHERE ts >= '2026-09-21' AND (input_toks IS NOT NULL OR output_toks IS NOT NULL) GROUP BY runner;`
shows `blank = 0` for every runner, and a re-run of the dry run prints
`candidates 0`.
