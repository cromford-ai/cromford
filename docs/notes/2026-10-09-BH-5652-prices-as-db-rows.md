# Prices are versioned DB rows, seeded from the committed files (BH-5652)

Doc: COST, DB-COORDINATION-SPEC

## What changed

- `model_prices` has two new columns, `version` (default 1) and `effective_at`.
  `ensureColumns` adds them to the live table. A POST that changes a rate bumps
  the version and writes one `price_audit` row in the same D1 batch. The same
  rates posted again write nothing. A `source=catalog` POST still only inserts
  (BH-1890).
- Three new D1 tables: `price_fly` (one row per number in
  `catalog/fly-prices.json`, dotted key), `model_slugs`
  (`catalog/model-slugs.json`) and `price_audit` (`UNIQUE(kind, key, version)`).
  The routes create them (BH-658).
- New routes: `POST`/`GET /api/fly-prices`, `POST`/`GET /api/model-slugs`,
  `GET /api/price-audit?kind=&key=&limit=`. `GET /api/model-prices` carries
  `version`, and `effective_at` once it is set.
- `bin/price-seed.sh` POSTs the three committed files once per content. The
  key is the sha256 of the three files, kept in `state/prices/seeded`. It runs
  at the end of `bin/update-model-prices.sh` (hub, 04:30Z). A failure raises
  the warn lane-alert `price-seed-failed`. A good seed resolves it.
- `bin/lib/jobs/cost.sh` has `price_fly_put` and `model_slugs_put`.
- `cost_row_price` writes `price_v:<n>` in a cost row's `note` when it priced
  the row from a table row with a version. The new `cost_price_version` reads it.
- A claude row has the token too. `bin/transcript-cost.sh` prices the
  transcript from the same table, and `--price-version` adds a 10th field: the
  version of the row it priced the top model from. `cost_row_source`, the
  advisor row and `bin/claude-cost.sh` write it as `price_v:<n>`. Without the
  flag the line keeps its 9 fields.
- The hub has no sync line, so its `state/model-prices.json` had no versions.
  After a good push, `bin/update-model-prices.sh` reads the versions back
  (`model_prices_versions_merge`). A model takes its D1 version only when its
  four rates equal the D1 row's. The catalog-behind compare ignores `version`
  and `effective_at`.
- `bin/model-prices-sync.sh` writes one `ALERTS.log` line a day when the API
  fails and the box prices from its cache. The line names what the API
  answered (`http=500`, `curl_rc=7`, `no-url`).

## Why

The ticket asks for prices as DB rows with a version, an audit trail, and a
cost row that says which price version it used. The model price table was
already in D1 (BH-1032) and the refresh already made no commit (BH-628). This
wave adds the versions, the audit, and the two missing tables.

## What did not change

- The ticket names a new table `price_models`. This wave extends the existing
  `model_prices` table instead. It is the fleet's one model price table
  (BH-1032, BH-3990), and a second table for the same fact breaks that rule.
  Wave 2 of #5637 must plan against `model_prices`.
- The box cache path stays `state/model-prices.json`.
  `tests/pricing-one-table.bh-3990-test.sh` pins seven readers to it.
- The readers of `catalog/fly-prices.json` and `catalog/model-slugs.json` still
  read the files. The new tables are mirrors with a history.
- `cost.csv` has no new column. The version rides the existing `note` column.
- Envelope dollars (a claude run with no transcript) and the grok vendor
  figure carry no `price_v:`. They did not come from the table.
- `effective_at` on a version-1 row from before this wave is the time the
  first POST after deploy saw those rates. Read it as "first observed", not as
  the date the rates took effect.

## Operator checks after deploy

- `HUB_PROBE: d1-count price_fly all` answers 5 after the first 04:30Z refresh.
- `HUB_PROBE: d1-count model_slugs all` answers 34 (today's slug map).
- `HUB_PROBE: d1-count price_audit all` answers more than 0.

Tests: `worker/jobs/test/price-versions.bh-5652.test.js`,
`tests/price-refresh-no-commit.bh-5652-test.sh`,
`tests/price-fallback.bh-5652-test.sh`, `tests/price-db-parity.bh-5652-test.sh`,
`tests/cost-row-price-version.bh-5652-test.sh`,
`tests/transcript-price-version.bh-5652-test.sh`.
