# config_changes: worker audit rows for cap, topic, seed and rule-delete writes (BH-2996, BH-2992.2)

Doc: DB-COORDINATION-SPEC

## What changed

Four worker routes now write a `config_changes` row in the same `env.DB.batch`
as the write it records, through the BH-2994 contract
(`worker/jobs/src/lib/config-changes.js`). Each one calls
`ensureTable(env, 'config_changes')` before it reads or writes.

- **Cost caps, both paths (D15).** `PUT /api/cost-caps` and the cap branch of
  `PUT /api/settings` (`conf.cost-caps.*` / `conf.lane-caps.*`, box rows
  included) each add a `cost_cap` row next to the `cost_cap_changes` row they
  already wrote. The name is the full key and before/after are `{"value": …}`.
  The settings path uses the same reason as `cost_cap_changes`
  (`body.reason ?? body.note`). An unchanged value still writes neither row.
- **`DELETE /api/rules`.** It reads the rule first. When the rule was there, it
  batches the DELETE with a `concurrency_rule` delete row: `before_json` is the
  rule, `after_json` is the text `'null'`, and actor and reason come from the
  body. Deleting an absent rule writes no row, and a 400 writes nothing. The
  response is unchanged (`deleted` is still the DELETE's change count).
- **`PUT /api/telegram-topics`.** A changed or new `thread_id` adds a
  `telegram_topic` row, named by the project. Writing the same `thread_id`
  again still runs the upsert but writes no row. No reason is required: the box
  CLI path sends none, and it is stored as NULL.
- **`POST /api/settings/seed-registry/apply`.** The `applied` update now goes
  in one batch with a `registry_seed` row: name = `plan_fp`,
  after = `{plan_fp, run_id}`, with the caller's actor and `body.reason`. It is
  written even when the seed changed 0 rows. A refused apply (400, 409) and
  the `failed` path write none.

## What did not change

- There is no schema change. `cost_cap_changes` is untouched.
- `POST /api/cost-caps/seed`, `POST /api/settings/seed-registry` (the CLI
  seed) and `PUT /api/review-gate` still write no audit row.

## Tests

- `worker/jobs/test/cost-cap-config-changes.bh-2992.test.js`
- `worker/jobs/test/config-changes-delete.bh-2992.test.js`
- `worker/jobs/test/hub-write-reason.bh-2992.test.js`
- The header of `worker/jobs/test/config-changes-routes.bh-2618.test.js` now
  says a DELETE of an absent rule writes none. Its assertions did not change.
