# One price table, the missing rows, and `row_source=killed` (BH-3990)

Doc: COST

## What changed

- **The committed catalog's age is watched.** `bin/update-model-prices.sh` (hub,
  04:30Z) reads `catalog/model-prices.json`'s own `updated_at` before the
  OpenRouter fetch, so a failed refresh cannot hide it. Older than
  `MODEL_PRICES_CATALOG_MAX_AGE_DAYS` days (settings row
  `lane.update-model-prices.model_prices_catalog_max_age_days`, default 14,
  0 = off, a non-integer is the default), or no readable stamp: one warn
  lane-alert, id `model-prices-catalog-stale`. Within the threshold: that id is
  resolved. No `lane-alert.sh`: one `alert-line.sh` line. It sits beside the
  existing `model-prices-catalog-behind` drift notice; it does not replace it.
- **`claude-haiku-4-5-20251001` is priced.** A slug line in
  `catalog/model-slugs.json` (the half that reaches the DB: the refresh builds
  the live table from that map alone) and a catalog row copied byte for byte
  from `claude-haiku-4-5`. `cost_price_tokens` and the rollup's `row_cost` look
  the model up by exact key, so the dated id was `UNPRICED:no-price` on any row
  not priced from a transcript.
- **A context-killed call says so in `row_source`.** `bin/agent-call.sh`
  `ac_cost_row_write` sets `row_source=killed` on a claude row whose
  `$OUT.ctxkill` marker exists. Its tokens stay whatever the transcript held,
  and are blank (not 0) when it could not be read. The note keeps
  `context-kill:` / `cliff-avoided:`, so `ctx_kill_repeats` is unaffected.
  `tests/context-kill.bh-653-test.sh` case 9 now expects `killed`.

## The audit: does the vendor call happen before the stop?

| path | where in `bin/agent-call.sh` | vendor call before the stop? | row |
|---|---|---|---|
| call-guard repeat / counter-unreadable | `call_guard_precall`, before `run_attempt` | no | `refused`, zeros, note `refused:call-guard:*` |
| call-guard per metered rung | `call_guard_rung_ok`, before the rung's CLI | no | `refused`, zeros |
| context-kill repeat | `ctx_kill_repeat_refuse`, before the guard | no | `refused`, zeros, note `refused:context-kill-repeat` |
| lane gate, runner mismatch, tripwire refusal | before any runner | no | `refused`, zeros |
| context meter kill (incl. cliff-avoided) | `context_meter` TERMs the child once transcript usage passes the ceiling | **yes**: it can only fire after billed responses | `killed`, transcript tokens (blank if unreadable) |

The build tripwire (BH-3481) also TERMs a running session; its rows keep
`transcript` with their `tripwire:` note. The ticket named context-kill and
call-guard only.

## Readers of the price table

Every box-side reader resolves `$HARNESS/state/model-prices.json` (the DB copy
`bin/model-prices-sync.sh` pulls) before any catalog:
`bin/lib/cost-row.sh` `_cost_prices_table` (`cost_price_tokens`,
`cost_model_cliff`), `bin/transcript-cost.sh`, `bin/cost-rollup.sh`
`_prices_path`, `bin/lib/cost-budget.sh` `cost_budget_rates_tsv`,
`bin/planned-files-cheap.sh`, `bin/orchestrate.sh` `turn_cost_usd`,
`bin/cache-hit-report.sh` `lane_cache_efficiency`. The worker and console read
D1 directly (`GET /api/model-prices`). `tests/pricing-one-table.bh-3990-test.sh`
runs the real sync against a DB answer that disagrees with the catalog and
checks every one of those readers prices from the DB, then falls back to the
catalog when the state file is gone. No reader changed.

`bin/mac/mac-burn-push.sh` still reads the catalog only: it runs on a Mac with
no harness-jobs credential, and its numbers are labelled notional.

## DeepSeek

The ledger read (`/api/metrics/cost-rows` since 2026-09-19, paged to the end)
found one DeepSeek id with `UNPRICED:no-price`: `deepseek/deepseek-v4-flash`,
30 rows, all on 2026-09-22 on project-4 pool boxes. It already has a catalog row
and a slug line (landed 2026-09-29), so nothing was added; the suite pins it.
