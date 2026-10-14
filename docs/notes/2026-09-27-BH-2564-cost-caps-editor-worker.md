# Cost-caps editor, worker half: validator, routes, audit, seed split (BH-2511 W1-W3, BH-2564)

Doc: DB-COORDINATION-SPEC

## What changed

This fills in the stubs BH-2563 left in `worker/jobs/src/routes/cost-caps.js`. It changes no reader: `bin/lib/cost-budget.sh` and `bin/lib/lane-caps.sh` are untouched, and they stay the source of truth for what a caps row means.

- **`worker/jobs/src/lib/cost-caps.js` (new)**
  - `CAP_KEY_PREFIX_RE` matches every `conf.cost-caps.*` / `conf.lane-caps.*` key, box rows included.
  - `capFleetKey(key)` accepts exactly the six fleet shapes and returns null for a box suffix or any extra segment. The shapes are `conf.cost-caps.budget.<s>`, `conf.cost-caps.default`, `conf.cost-caps.ceiling`, `conf.lane-caps.lane.<s>`, `conf.lane-caps.noise.<s>` and `conf.lane-caps.default`, where `<s>` is `[a-z0-9_-]+` and the key is at most 64 characters.
  - `validateCapValue(cap, value)` mirrors `_cb_row_ok` / `_lc_row_ok`. It takes `capFleetKey`'s result rather than a bare kind, because `default` is a kind in both files with two different grammars (`off` is a lane default and never a cost one).
  - `capChangeStmt(...)` is the prepared audit INSERT.
- **`PUT /api/cost-caps`** `{key, value, reason, actor}`
  - Every refusal is a 400 before anything is read or written: a key that is not a fleet key, a value that is not a string or fails the grammar, a blank reason, and the reserved `registry-seed` actor.
  - A value equal to the stored one answers `200 {setting, unchanged: true}` and writes nothing.
  - A change is the settings upsert (note = reason) and its `cost_cap_changes` row in ONE `env.DB.batch`, and answers `200 {setting, unchanged: false}`.
- **`GET /api/cost-cap-changes[?key][&limit]`** is newest first and returns `{changes, truncated, as_of}`.
  - `limit` uses the `/api/routing-changes` formula: default 100, clamped to 1..500, and `0` reads as absent.
  - `?key=` must be a cap key; box keys are allowed because the generic PUT audits them.
- **`POST /api/cost-caps/seed`** `{rows: [{key, value}]}`
  - The whole request is validated first. A missing, empty or non-array `rows`, more than 200 rows, any row failing the key or value check, or a duplicate key makes the whole request a 400 that writes and prunes nothing.
  - It then writes with `SEED_REGISTRY_SQL` under `registry-seed`. It also deletes seed-owned rows under the two cap prefixes that are no longer in `rows`. Both go in one batch.
  - An operator's row is never moved or deleted, because the actor guards are in the SQL. The seed writes no audit row.
  - It returns `{rows, changed, changed_keys, pruned, pruned_keys, actor, as_of}`.
- **`PUT /api/settings`** audits a cap key too (D15). When a `CAP_KEY_PREFIX_RE` key's value changes, its `cost_cap_changes` row (reason = `body.reason ?? body.note`) goes in the same batch as the upsert. It adds no validation, so box rows stay writable here. Every other key takes the old single-statement path.

## The seed-actor split

A box's settings cache files `registry-seed` rows under `seeded`, and `conf_rows` reads only `values` (`bin/lib/lane-gate.sh`, `bin/lib/conf-row.sh`). So a seed row binds nothing on a box, and only an operator's row (any other actor) overrides the file. Two seeds now share that actor:

- `POST /api/settings/seed-registry` owns the registry knobs.
- `POST /api/cost-caps/seed` owns `conf.cost-caps.*` / `conf.lane-caps.*`.

The registry seed's orphan prune, and `seedRegistryPlan` behind `harness-ctl seed-registry --dry-run`, now skip every `conf.*` key. Without that skip, the next registry seed would delete every caps seed row.

An operator who re-saves a seed-owned row with the SAME value gets `unchanged: true` and the row stays seed-owned. Changing the value is what makes the row theirs.

## Tests

- `worker/jobs/test/cost-caps.bh-2564.test.js`
- `tests/cost-caps-worker.bh-2564-test.sh`
- `worker/jobs/test/cost-caps-contract.bh-2563.test.js`: R1-R3 now pin the real answers instead of the stubs.
