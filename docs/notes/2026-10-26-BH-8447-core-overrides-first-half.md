# First 16 CREATED_TABLE_OVERRIDES tables move to core.d/ (BH-8447, slice C1 of BH-8395)

Doc: worker/jobs/README.md

## What changed

The first 16 tables of the `CORE_TABLE_OVERRIDES` literal in
`worker/jobs/src/lib/core.js` moved into one frozen baseline fragment each,
under `worker/jobs/src/lib/core.d/`:

`merge_trains`, `verdict_history`, `wakes`, `wake_claims`, `pr_state_events`,
`pr_attempts`, `model_routes`, `routing_changes`, `cost_cap_changes`,
`config_changes`, `harness_flags`, `model_route_changes`, `verdicts`,
`lead_protected_paths`, `setting_sigs`, `lead_review_requests`.

Each entry moved byte for byte, with its comment block. Each file exports only
`CREATED_TABLE_OVERRIDES = { <table>: [ ... ] }`. core.js lost those 16 entries.
Its header comment now says the overrides are the literal plus the `core.d/`
baselines. No statement changed: `CREATED_TABLE_OVERRIDES` and
`CREATED_TABLES` hold the same 35 tables and the same arrays as before. Only the
key order of `CREATED_TABLE_OVERRIDES` changed, and every reader looks up by key.

## The file-name rule

`0000-<table>.js`, with each `_` in the table name written as `-`
(`merge_trains` is `0000-merge-trains.js`). The composer's name pattern
(`CORE_FRAG_RE`) refuses `_` in a fragment name.

## How a later build edits a moved table

- A new statement for a moved table (an index, a trigger) is a new file,
  `core.d/<ticket-key>-<name>.js`, that exports
  `CREATED_TABLE_OVERRIDES = { <table>: ["..."] }`. The composer appends it
  after the baseline.
- An in-place edit to a moved table's `CREATE TABLE` (a new column in the
  CREATE itself) edits that table's own `0000-<table>.js`. Two builds that edit
  two different tables touch two different files and merge with no conflict.
- A table left in both the core.js literal and a fragment cannot load: the
  merge in core.js throws "names ... twice" at import.

## What is left (C2, BH-8448)

The other 19 tables (`risk_tiers` to `suite_reuse_runs`) stay in the core.js
literal. C2 moves them, deletes the literal and adds the
`catalog/list-files.tsv` row for core.js.

## Tests

- `worker/jobs/test/core-overrides.bh-8447.test.js` (node, `npm test`): the
  16 fragments, string-for-string equality with the pre-split fixture
  `worker/jobs/test/fixtures/core-overrides-pre-split.bh-8447.json` (all 35
  tables, built from main's core.js before the move, so C2 uses it too), and
  the real `ensureTable` on node:sqlite.
- `tests/core-overrides-split.bh-8447-test.sh`: the files exist, and two
  branches that edit `0000-verdicts.js` and `0000-wakes.js` merge with no
  conflict.
