# Cost-caps contract: table, stub routes, Costs page mount points (BH-2511.0, BH-2563)

Doc: COST, DB-COORDINATION-SPEC

## What changed

This is the first of five slices of BH-2511, where caps become settings rows editable on /costs. It adds shapes and stubs only. Nothing validates, nothing writes `cost_cap_changes`, and no reader changes (`bin/lib/cost-budget.sh` and `bin/lib/lane-caps.sh` are untouched).

- **Table `cost_cap_changes`** (`id, key, before_value, after_value, actor, reason, at`) plus `idx_cost_cap_changes_key ON (key, at)`. It lives in `worker/jobs/schema.sql` after `routing_changes`, and the same statements are in `CREATED_TABLES` in `worker/jobs/src/lib/core.js`. Both are `IF NOT EXISTS`. Nothing writes the table yet.
- **Route stubs** in `worker/jobs/src/routes/cost-caps.js`, registered in `src/index.js` right after `routing`:
  - `PUT /api/cost-caps` answers `501 {error:"not implemented"}`.
  - `GET /api/cost-cap-changes` answers `200 {changes:[], truncated:false}`. It reads no table and ignores `key`/`limit`.
  - `POST /api/cost-caps/seed` answers `501 {error:"not implemented"}`.
  All three stay behind the bearer.
- **Console API** (`console-ui/src/api.js`):
  - `putCostCap({key, value, reason})` sends a PUT to `/api/coord/cost-caps` with exactly those three fields and no actor.
  - `costCapChanges({key, limit})` sends a GET to `/api/coord/cost-cap-changes`, adding only the parameters it was given.
- **Coord proxy**: one `WRITES` row admits `PUT cost-caps` exactly. It forwards `key`, `value` and `reason` as strings only, and the actor is stamped the way every row's is. This replaces the `stampsActor` list the ticket names, which BH-2405 retired. `cost-caps/seed` and every other verb on `cost-caps` stay 405, because the seed is hub-bearer only.
- **Mount points**: `console-ui/src/screens/CostCaps.js` (`CostCapsSection`) and `CostCapHistory.js` (`CostCapHistorySection`) each render `null`. They are mounted in `Costs.js` directly below `CostBreakerSection`, CAPS first, then HISTORY. /costs looks exactly as it did before.

## Why 225 and not 545

The ticket names the route-table fragment `545-cost-caps.txt`. `545-fly-images.txt` (BH-2523) already holds that number, and `route-table.test.js` refuses two fragments sharing one. The family sits next to `routing` (fragment 220) in `ROUTES`, so its fragment is `225-cost-caps.txt`.

## Tests

- `worker/jobs/test/cost-caps-contract.bh-2563.test.js`
- `console-ui/tests/cost-caps-contract.bh-2563.test.js`
- `tests/cost-caps-contract.bh-2563-test.sh`
