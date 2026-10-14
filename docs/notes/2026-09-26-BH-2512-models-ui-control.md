# The Models page removes routes, flips price sources, and lists unrouted stages

Doc: MODEL-ROUTES

## What was wrong

The worker already had both writes: `POST /api/model-routes/remove` (BH-1572,
tombstoned by BH-1928) and `PUT /api/model-prices/source` (BH-1613). The coord
proxy's WRITES allowlist did not admit either, so Mission Control answered 405
and both stayed CLI-only (`bin/jobs-client.sh`). Nothing showed which stages ran
with no `stage.*` route, so a stage silently running on claude was only visible
in `failovers.log` on the box that ran it.

## What changed

- `console-ui/functions/api/coord/[[path]].js`: two WRITES rows.
  `model-routes/remove` forwards `role, project, expected_version, reason`;
  `project` travels on purpose, so the worker's hub-only 400 stays the gate.
  `model-prices/source` forwards `model, price_source` as strings only; the
  `vendor` rate object is not admitted and stays a CLI action. Actor is stamped
  as for every other write.
- `GET /api/model-routes?unrouted_since=<ts>` (opt-in; no param, no change and no
  extra query) adds `unrouted_stages`: every lowercased `cost_rows.stage` since
  `<ts>` with no rung-0 `stage.<stage>` row at the call's project or the hub.
  That is the rule agent-call's resolver applies, so a gapped ladder still
  counts as unrouted. A stage whose `stage.<x>` is not a valid role name is
  listed with `role: null`. Capped at 500 (stage, project) pairs with
  `unrouted_truncated`. A failed ledger read answers `unrouted_stages: null` and
  `unrouted_error`, and the routes still render.
- `/models` asks for it with the same 7-day window as the spend columns
  (`SPEND_DAYS`) and shows UNROUTED STAGES; the hub tab shows MODEL PRICES with
  the source toggle. `/models/<role>` on the hub shows REMOVE ROUTE. Both writes
  go through the in-app confirm modal and `makeModelActions`' status contract
  (409 = stale + reload, any other failure = failed, never written).

No schema change, no new knob.
