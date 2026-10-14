# New unpriced pair alert: no usage is a parse problem, not a catalog one

Doc: COST

BH-2306's `NEW UNPRICED PAIR` line had two diagnoses, keyed on `priceable`
alone. A call that returned no token counts (the `UNPRICED:no-usage` row
`cost_row_price` writes: rc 0, blank tokens, blank cost) always prices at $0,
so its pair read as unpriceable and the line said "not in catalog — add it",
even for a model the catalog prices. The fix for that pair is the runner's
usage parse.

`ledger_unpriced_pairs()` in `bin/cost-rollup.sh` now also reports, per pair,
`in_catalog` (the price-table lookup `row_cost` makes) and `no_usage` (calls
with zero tokens). The alert builds the diagnosis from those:

- calls with no usage: `<n> call(s) reported no usage — runner <r> returned no
  token counts; fix its usage parse: <parser>`. The parser is
  `bin/agent-call.sh run_attempt claude branch` for claude,
  `bin/codex-usage.sh` for codex, openrouter and fireworks,
  `bin/grok-usage.sh` for grok, and `no usage parser mapped for runner <r>`
  for anything else.
- tokened calls on a model the catalog has: "catalog prices it — the writer
  on that box is not pricing at the call site" as before, or, when that row
  prices the tokens at $0, "check that row's rates".
- a model the catalog does not have: "not in catalog/model-prices.json — add
  a price row". This is the only case that asks for a price row.

A pair can carry more than one part (a mixed pair, or no usage on an unknown
model); the parts join with `; `. A summary written before this change has no
`in_catalog`, and the alert falls back to `priceable`, which gives the old
two-way diagnosis. Pinned by `tests/unpriced-no-usage-diagnosis.bh-2416-test.sh`.
