# Last 19 CREATED_TABLE_OVERRIDES tables move to core.d/, the literal is gone (BH-8448, slice C2 of BH-8395)

Doc: worker/jobs/README.md

## What changed

The other 19 tables of the `CORE_TABLE_OVERRIDES` literal in
`worker/jobs/src/lib/core.js` moved into one frozen baseline fragment each,
under `worker/jobs/src/lib/core.d/`, with the C1 file-name rule
(`0000-<table>.js`, `_` written as `-`):

`risk_tiers`, `jev_risk_calls`, `queue_risk_scores`, `route_rules`,
`route_rule_changes`, `route_shadow`, `triage_state`, `alert_family_scripts`,
`dequeue_events`, `dequeue_actions`, `projects`, `pool_spawns`,
`pool_terminals`, `pool_holds`, `conflict_hotspots`, `conflict_hotspot_runs`,
`participant_machines`, `suite_results`, `suite_reuse_runs`.

Each entry moved byte for byte, with its comment block. The `DQW_CLASS_SQL`
constant (the nine dequeue-watch class words, BH-3727) moved too: each of the
two dequeue fragments holds its own unexported copy, because a fragment is a
plain data module with no imports.

core.js has no literal now. It exports the composed map directly:
`export const CREATED_TABLE_OVERRIDES = FRAGMENT_TABLE_OVERRIDES;`, and it no
longer imports `mergeTableLists` (the function stays in `core-registries.js`;
tests use it). No statement changed: `CREATED_TABLE_OVERRIDES` and
`CREATED_TABLES` hold the same 35 tables and the same arrays as before. Only the
key order changed (file-name order), and every reader looks up by key.

## The catalog row

`catalog/list-files.tsv` now lists core.js:

    worker/jobs/src/lib/core.js	worker/jobs/src/lib/	registry entry since BH-8448: ...

`bin/list-file-lint.sh` refuses a PR that grows core.js (more lines added than
deleted) and adds no new file under `worker/jobs/src/lib/`. An in-place edit or
a shrink of core.js passes. An edit of a `core.d/0000-*` baseline passes.

The input dir is `worker/jobs/src/lib/`, not `core.d/` (assumption A1 of the
plan). core.js also holds constants, transition graphs and pure functions, and
`core.d/` takes only the three registry exports. A PR that adds such code puts
it in its own `src/lib/` module. A registry entry is still a new
`core.d/<ticket-key>-<name>.js`, which is under the same dir.

## How a later build edits an override

- A new statement for a table is a new file `core.d/<ticket-key>-<name>.js`
  that exports `CREATED_TABLE_OVERRIDES = { <table>: ["..."] }`. The composer
  appends it after the baseline.
- A change to a table's `CREATE TABLE` edits that table's own
  `0000-<table>.js`. Two builds that edit two different tables touch two
  different files and merge with no conflict.

## Tests

- `worker/jobs/test/core-overrides.bh-8448.test.js` (node): the 19 fragments,
  string-for-string equality with the pre-split fixture
  `worker/jobs/test/fixtures/core-overrides-pre-split.bh-8447.json`, the loader
  and core.js hold all 35 tables, each core.js override is the loader's own
  array (no literal copy), and the real `ensureTable` keeps the dequeue CHECKs.
- `tests/core-overrides-split.bh-8448-test.sh`: the files exist, the catalog
  row's red and green cases against the real catalog, and two branches that
  edit `0000-risk-tiers.js` and `0000-dequeue-events.js` merge with no conflict.
- `worker/jobs/test/core-overrides.bh-8447.test.js` S1 and S4 now allow the
  19 C2 baselines (their premise was "the other 19 are still in the literal").
