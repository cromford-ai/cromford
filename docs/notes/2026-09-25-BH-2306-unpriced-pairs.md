# Unpriced cost rows: who is behind them, and a daily alert for a new pair

Doc: COST

## What the ticket saw

BH-2306 counted 1,237 unpriced cost rows for cromford and 1,213 for
project-5 ("unpriced" = `cost_usd IS NULL` in D1, the definition
`worker/jobs/src/routes/usage.js` counts). Every daily cap and the Costs page
read those rows as $0.

## How the pairs were identified

A read-only pull of `GET /api/metrics/cost-rows?project=<p>&since=<now-7d>&limit=2000`,
paged backwards with `until` = the oldest `ts` on the page and deduped on
`(box, row_hash)`, the same walk `cost_rows_fetch` in `bin/lib/cost-rows-read.sh`
does. Rows with `cost_usd` null were grouped by runner, model and whether they
carried any tokens.

As of 2026-09-25 16:22Z (window from 2026-09-18 16:22Z). The ticket's larger
counts were taken earlier, before some rows aged out of the 7-day window.

| runner / model | cromford | project-5 | tokens | last seen |
|---|---|---|---|---|
| openrouter / deepseek/deepseek-v4-flash | 466 rc 1, 1 rc 124, 1 rc 127 | 525 rc 1 | none | 2026-09-24 |
| fireworks / accounts/fireworks/models/kimi-k2p7-code | 245 | 165 | yes | 2026-09-20 02:24Z |
| openrouter / deepseek/deepseek-v4-flash | 161 | 62 | yes | 2026-09-21 00:08Z |
| openrouter / anthropic/claude-fable-5.1 | 27 | 23 | yes | 2026-09-19 |
| codex / gpt-6-astra | 18 (+23 no-token rc 1) | 0 | mixed | 2026-09-19 |
| grok / grok-4.7 | 13 rc 1 | 0 | none | 2026-09-24 |
| fireworks / accounts/fireworks/models/deepseek-v4-flash-0731 | 8 (+4 no-token rc 1) | 1 | mixed | 2026-09-19 |
| openrouter / anthropic/claude-opus-5 | 5 | 4 | yes | 2026-09-19 |
| openrouter / anthropic/claude-sonnet-5 | 0 | 2 | yes | 2026-09-19 |
| claude / claude-opus-5 | 1 rc 127 | 1 rc 127 | none | 2026-09-24 |

Totals in that window: cromford 973 null rows of 6,331, project-5 783 of
5,554. Token-bearing null rows by day: cromford 163 / 298 / 3 on
09-18 / 19 / 20; project-5 58 / 188 / 2 / 9 on 09-18 / 19 / 20 / 21. There
have been none since 2026-09-22. Every null row after that is a failed call
with no tokens.

## What that means

1. Every model above is already in `catalog/model-prices.json`, so there were
   no price rows to add. The token-bearing rows were written before the call
   site priced the openrouter, fireworks and codex branches (`cost_row_price`
   in `bin/lib/cost-row.sh`, BH-1020). They stay null in D1 and age out of the
   7-day Costs window around 2026-09-28. They are not backfilled.
   `tests/unpriced-pairs-priced.bh-2306-test.sh` now fails if any of these
   models stops pricing through `cost_price_tokens` / `cost_row_price`.
2. The existing daily UNPRICED alert could not see these rows.
   `unpriced_pairs()` in `bin/cost-rollup.sh` skips a row when `row_cost()` is
   non-zero, and `row_cost()` re-prices a blank `cost_usd` from its tokens when
   the model is in the table. A row D1 stores as null, for a model the catalog
   prices, read as priced to the rollup.
3. More than half of the null rows are failed calls with no tokens. They were
   never billed, so they are not missing spend. They do inflate the worker's
   `unpriced_calls` count, which this change leaves alone.

## What changed

- `ledger_unpriced_pairs()` in `bin/cost-rollup.sh` groups the last 24h of
  billed rows whose STORED `cost_usd` is blank (not refused, not a zero-token
  failure) by trimmed runner/model, with `priceable` saying whether the catalog
  could have priced them. It is written to `summary.json` as
  `fleet_ledger_unpriced_pairs_24h`.
- The `# >>> new unpriced pair alert` block pages one
  `[cost-rollup] NEW UNPRICED PAIR(S): ...` line a day
  (`flags/alerted-unpriced-new-<YYYYMMDD>`) for any pair not yet in D1 `ledgers`
  kind `unpriced_pair` (key `runner|model`). The line goes out first, then the
  flag and a `job_ledger_put` for each new pair it named. A pair the ledger
  can't confirm (outage, no secret) is alerted and tagged `(seen-set
  unreadable)`, and it is not marked.
- Driven by `tests/unpriced-new-pair.bh-2306-test.sh`, including one whole
  `bin/cost-rollup.sh` run with `WINDOWS_ONLY=1` in a scratch tree.
