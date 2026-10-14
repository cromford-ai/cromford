# The vendor-direct price moves into D1, and a failed marks read stops the refresh

Doc: model-prices

BH-1754, a follow-up to BH-1613.

## What changed

- **A failed read fails closed.** `bin/update-model-prices.sh` reads the
  `price_source` marks through `model_prices_get` before it prices anything.
  The read passes `MODEL_PRICES_MIN=0`: the 5-row floor is for boxes syncing
  the table, and a fresh or wiped D1 this lane has not seeded yet is a good
  read, not a failure. If that GET fails, or answers without a `per_token`
  object, the lane now
  raises one `lane-alert.sh --severity warn --id
  model-prices-price-source-unreadable` and exits. It does not write
  `state/model-prices.json`, `state/openrouter-models.json` or the DB copy, so
  all three keep yesterday's rates. Before this it re-priced every model from
  OpenRouter and said so only in `agent-rules.log`. That was the one case where
  a vendor-direct model silently went back to OpenRouter's resale rate. The next
  good read sends `--resolve` for that id. A box with no jobs-client has no
  marks to read and is unchanged.
- **The vendor price lives on the D1 row.** `model_prices` gains five nullable
  columns next to `price_source`: `vendor_prompt`, `vendor_completion`,
  `vendor_cache_read`, `vendor_cache_write`, `vendor_cliff_tokens`. They are added
  by `ADDED_COLUMNS` on the worker's first request after deploy, the same path
  `price_source` used. `PUT /api/model-prices/source` is still the only writer.
  It takes an optional `vendor` object, goes with `vendor-direct` only, and needs
  `prompt` and `completion` as numbers > 0 (otherwise 400). `openrouter` clears
  the mark and the rates. `vendor-direct` with no `vendor` keeps the stored rates.
  The refresh's whole-table POST never names these columns.
- `GET /api/model-prices` emits them as `vendor_direct` on a marked row only.
- The refresh prices a marked model from D1 first, then from the committed
  catalog row, then from OpenRouter with an `agent-rules.log` line. A D1 price
  overlays the catalog row per field: a cache rate or cliff left unset in D1
  comes from the catalog, so the minimal `<prompt> <completion>` form keeps
  grok's 200K cliff.
- The verb is `bin/jobs-client.sh model-price-source <model> vendor-direct
  <prompt> <completion> [cache_read [cache_write [cliff_tokens]]]`. So editing a
  vendor rate is one command, with no PR against `catalog/model-prices.json`.

## Why

Issue #1754: a failed read should alert and keep the table, not re-price from
the fallback. The vendor rate should be data in D1 next to the flag, with the
catalog file kept as the fallback.
