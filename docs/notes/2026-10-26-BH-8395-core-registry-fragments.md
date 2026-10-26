# Jobs worker schema registries compose from core.d/ (BH-8395, slice C0)

Doc: worker/jobs/README.md

## Why

`worker/jobs/src/lib/core.js` had 13 merge conflicts in 30 days. Most of the
hunks landed in three literal maps: `ADDED_COLUMNS` (8 hunks since
2026-09-20), `CREATED_TABLE_OVERRIDES` (6) and `ADDED_INDEXES` (2). Every build
that added a column or an index edited the same lines.

## What changed

- `ADDED_COLUMNS` and `ADDED_INDEXES` moved out of core.js into two frozen
  baseline fragments: `worker/jobs/src/lib/core.d/0000-added-columns.js` and
  `worker/jobs/src/lib/core.d/0000-added-indexes.js`. The values are the same,
  key order included (the suites compare them with
  `worker/jobs/test/fixtures/core-registries-pre-split.bh-8395.json`, built
  from main's core.js before the split).
- core.js imports the three names from `#core-registries` and still exports
  `ADDED_COLUMNS`, `ADDED_INDEXES` and `CREATED_TABLE_OVERRIDES`. Every
  importer reads the same names and values.
- `#core-registries` (`worker/jobs/package.json` imports): under wrangler
  (`workerd`) it is the git-ignored render `src/lib/core-registries.gen.js`.
  Under node (`default`) it is `src/lib/core-registries.node.js`, which reads
  `core.d/` at load time.
- `worker/jobs/scripts/core-registries-build.mjs` writes the render.
  `wrangler.jsonc` `build.command` runs it after `routes-build.mjs`, so a
  deploy always bundles registries made from its own fragments.
  `--check` composes every fragment, renders twice and compares, and fails on a
  tracked or stale gen file. `--print` and `--out <path>` work as in
  `routes-build.mjs`.

## The fragment rule

A new column, a new added index or a new statement for an existing override
table is a NEW file, never a core.js edit and never an edit to a `0000-*`
baseline:

```js
// worker/jobs/src/lib/core.d/bh-9001-verdicts-foo.js
export const ADDED_COLUMNS = {
  verdicts: [["foo", "TEXT"]],
};
```

- Name: `<NNNN>-<name>.js` (a baseline) or `<ticket-key>-<name>.js`
  (`bh-9001-x.js`, `bh-6005-4-x.js`, `bh-5235.2-x.js`). The name part is
  lowercase letters, digits and `-`.
- Exports: one or more of `ADDED_COLUMNS`, `ADDED_INDEXES`,
  `CREATED_TABLE_OVERRIDES`, each `{ <table>: [items] }`. No imports.
- Order: file names sort with `[...names].sort()`, so every `0000-*` baseline
  comes first. For each table the items concatenate in that order. The first
  fragment that names a table fixes its key position.
- Refused (the loader throws at import, the render fails, and so the deploy
  fails): a bad file name (a stray `README.md` too), an unknown export, a
  fragment with no registry export, a table name that is not `[a-z_][a-z0-9_]*`,
  an `ADDED_COLUMNS` item that is not a `["name", "TYPE"]` pair, the same column
  or statement twice for one table.
- `CREATED_TABLE_OVERRIDES` in core.js is the in-core literal (now
  `CORE_TABLE_OVERRIDES`) merged with the fragment overrides by the same
  concat rule. In C0 no override fragment exists. A fragment may append a
  statement to a table the literal already has. It must not name a new table:
  that replaces the derived entry, and `test/created-tables.bh-4987.test.js`
  T3 refuses a new override key.

## What is left (C1, C2)

- C1 moves the first half of the `CREATED_TABLE_OVERRIDES` literal into
  per-table `core.d/0000-<table>.js` fragments.
- C2 moves the rest, deletes the in-core literal and adds the
  `catalog/list-files.tsv` row for core.js. Until C2 an in-place edit to an
  override CREATE has no fragment path, so the row waits.

## Tests

- `worker/jobs/test/core-registries.bh-8395.test.js` (node, `npm test`).
- `tests/core-registries-merge.bh-8395-test.sh`: two sibling branches each add
  a column fragment and merge with no conflict; the render and `--check`.
