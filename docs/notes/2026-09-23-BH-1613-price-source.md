# A per-model price source: vendor-direct models keep the catalog rate

Doc: model-prices

BH-1613.

## What changed

`model_prices` has a nullable `price_source` column. `vendor-direct` means the
model is billed at the vendor's own rate. NULL means OpenRouter, which is how
every model priced before this.

- `PUT /api/model-prices/source {model, price_source}` is the only writer.
  `openrouter` stores NULL. A bad value is 400 and a model with no row is 404.
  The operator verb is `bin/jobs-client.sh model-price-source <model>
  <vendor-direct|openrouter>`.
- `GET /api/model-prices` carries `price_source` only on a marked row, the same
  way it carries `cliff_tokens`.
- The refresh's whole-table `POST /api/model-prices` never names the column, so
  the 04:30 run can't clear a mark.
- `bin/update-model-prices.sh` reads the GET before it prices anything. For each
  marked key in the slug map it copies the `catalog/model-prices.json` row
  verbatim (rates, slug, cliff). That row equals the fallback, so the
  catalog-behind notice doesn't count it.
- `/models` in the console tags a marked primary `DIRECT`, and the role page
  tags the marked rung.

## Why

xAI bills grok-4.7 direct at $2 in / $0.50 cached / $6 out with a 200k cliff.
OpenRouter lists it at $1.60, so every morning the refresh under-priced it and
the catalog-behind notice fired for a rate that was right in the catalog.

## Edges

- A marked model with no catalog row keeps its OpenRouter price, with one
  `agent-rules.log` line naming it.
- If the GET fails, every model prices from OpenRouter this run, with one
  `agent-rules.log` line saying the overrides were unreadable.
- Marks are per model key. Marking `grok-4.7` doesn't mark `x-ai/grok-4.7`.
- The ticket's optional multiplier is not built. A multiplied live rate would
  differ from the catalog and re-fire the notice daily. Put a regional uplift in
  the catalog row itself.
- The row's `source` column still reads `openrouter` (the lane that wrote it).
  `price_source` is the field that says where the rate came from.
