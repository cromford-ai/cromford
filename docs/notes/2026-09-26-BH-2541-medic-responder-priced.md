# alerts-medic and watchdog-responder are priced in full

Doc: COST

## What changed

`catalog/llm-sites.json` now marks `alerts-medic` and `watchdog-responder` as
`"priced": "yes"`. Before this they said `"partial"`. Both notes now say where
the unpriced rows came from. No code changed.
`tests/llm-sites-priced.bh-2541-test.sh` pins the claim and the pricing
behind it.

## Why

The goal-gap audit (C11) found medic and responder rows with no `cost_usd`.
The 7d `cost_rows` ledger, read 2026-09-26 while planning, shows where they
came from. The build re-read everything since 2026-09-19T23:25Z at 02:16Z
before flipping the catalog, and found no NULL medic or responder row:

- medic: 380 rows, 157 with NULL `cost_usd`. The last NULL row is
  2026-09-19T23:24:45Z. The first priced one is 23:26:27Z. After that, all
  223 rows are priced.
- responder: 34 rows. The 6 NULL rows all come before 2026-09-19T16:19Z.
  The 17 rows after the cutover are priced.
- None of the NULL rows has an `UNPRICED:` note.

A row with blank dollars and no note is what the identity stub for
`cost_row_price` writes (`bin/agent-call.sh`, the stale-library fallback). That
stub runs when `bin/lib/cost-row.sh` has not been synced. The hub picked up the
BH-1020 write-time pricer at about 2026-09-19T23:25Z. From then on, every medic
and responder row carries dollars.

## Where the fix actually lived

It lived in BH-1020's `cost_row_price` in `bin/lib/cost-row.sh`, once the hub
synced it. The codex usage parser (`bin/codex-usage.sh`) is fine. So is every
price key in `catalog/model-prices.json` these lanes use
(`accounts/fireworks/models/deepseek-v4-flash-0731`,
`accounts/fireworks/models/kimi-k2p7-code`, `gpt-6-astra`,
`deepseek/deepseek-v4-flash`). The new suite drives `bin/agent-call.sh triage
medic` on the fireworks rung with the real medic row's token counts. It checks
that the row lands priced, and that it goes `UNPRICED:no-price` when the key is
removed.

## When the view goes clean

The 7d fleet-cost window drops its last pre-cutover NULL row at about
2026-09-26T23:25Z. We did not backfill the historical rows. That would be a
production write from a build.
