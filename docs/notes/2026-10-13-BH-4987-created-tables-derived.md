# CREATED_TABLES derives from worker/jobs/schema.d (BH-4987, slice C5)

Doc: DB-COORDINATION-SPEC, OPERATOR-SETUP

## What changed

- `worker/jobs/src/lib/core.js` `CREATED_TABLES` is no longer a hand copy of
  the schema. It is `{ ...createdTablesFrom(SCHEMA_SQL), ...CREATED_TABLE_OVERRIDES }`:
  - `createdTablesFrom` (`worker/jobs/src/lib/created-tables.js`) maps the
    composed jobs schema to every `CREATE TABLE IF NOT EXISTS` and the
    `CREATE [UNIQUE] INDEX IF NOT EXISTS … ON <table>` statements for it, in
    schema order. It ignores comments, `INSERT`, `CREATE VIEW` and every other
    statement.
  - `SCHEMA_SQL` comes from the `#schema-sql` subpath import in
    `worker/jobs/package.json`. Under the `workerd` condition (the wrangler
    bundle) it is `schema.sql`, loaded as a Text module
    (`worker/jobs/wrangler.jsonc` `rules`). Under Node it is `jobsSchemaSql()`
    from `worker/jobs/test/lib/jobs-schema.js`.
- The map now has an entry for all 153 schema tables (59 before). A table still
  creates itself only where a route calls `ensureTable` for it.
- This slice deletes 24 hand entries (`account_leases` … `call_guard`). Their
  derived statements equal the deleted ones, and
  `worker/jobs/test/fixtures/created-tables-hand.bh-4987.json` pins that.
- 35 hand entries stay as overrides. 30 of them equal the derived form, and a
  later slice deletes them. 5 differ on purpose: `merge_trains` (creates
  `train_group` up front), `verdicts` and `setting_sigs` (append-only
  triggers, which `schema.d` may not hold), `pr_state_events` (the `pr_state`
  view) and `harness_flags` (its `pause_flags` backfill).
- `worker/jobs/test/created-tables.bh-4987.test.js` refuses a new override key
  and an override that drifts from the schema.

## Operator steps

- A new self-creating table is one `worker/jobs/schema.d` fragment plus the
  route's `ensureTable` call. Do not add it to `core.js`.
- A hand `wrangler deploy` in `worker/jobs` must first compose the schema:
  `bin/schema-build.sh --worker jobs --write`. Without `schema.sql` the bundle
  fails to resolve `../../schema.sql`. This is the same kind of precondition as
  `bin/lanes-build.sh --write` and `bin/llm-sites-build.sh --compose`.
  `bin/harness-sync.sh` already composes it before every automatic deploy.
- A suite that copies only `worker/jobs/src` into a scratch tree must also copy
  `worker/jobs/package.json`, `worker/jobs/schema.d/` and
  `worker/jobs/test/lib/{jobs-schema.js,schema-sql.node.js}`.

## Why

Every self-creating table was two hand edits: the `schema.d` fragment and a
copy of its DDL in `core.js`. Two builds that each added one collided at the
end of the `CREATED_TABLES` literal.
