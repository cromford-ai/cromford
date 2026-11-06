# BH-8986: catalog/state-paths.json is composed from catalog/state-paths.d/

Doc: docs/STATE-STORES.md

What changed: every S1 fix of `tests/no-state-files.bh-4159-test.sh` added a
row to the one `paths` array of `catalog/state-paths.json`. Two PRs that each
added a row both put a comma on the same last row line and both inserted
before the same `  ]`. #8931 stopped on `conflict-unresolvable:
catalog/state-paths.json`. This uses the BH-6487 pattern of
`bin/context-budgets-build.sh`.

The sources are in `catalog/state-paths.d/`:

- `_head.json`: the keys before `paths` (`version`, `about`).
- `0000-base.json`: the 59 rows of the old file, text verbatim.
- `NNNN-<name>.json`: one NEW file per added row, NNNN = the ticket number
  (4 or 5 digits). It is a JSON array. Its first line is `[` and its last
  line is `]`.

`bin/state-paths-build.sh` composes `catalog/state-paths.json`. At the split
commit the composition is the old file byte for byte. The composed file is
git-ignored. `--check` is rc 1 when it is tracked.

The composer refuses (rc 2, nothing is written): a missing `_head.json` or one
with a `paths` key; a bad file name; a fragment that is not a non-empty array
of objects with a string `path`; no fragment; a path twice. The class of a row
is still checked by `bin/state-paths-guard.sh`.

Readers:

- `bin/state-paths-guard.sh` and `bin/pool-state-paths-lint.sh` compose into a
  temp file when no catalog is given and `catalog/state-paths.d/` exists. A
  refused compose is rc 2.
- `bin/state-drain.sh` composes from `$H/catalog/state-paths.d/` when it
  exists. The box keeps a stale `catalog/state-paths.json` (the catalog rsync
  has no `--delete`), and the drain never reads it then. A refused compose
  refuses the run: nothing is deleted.
- `tests/lib/scratch.sh` composes the file at its path for the suites.
- `bin/test-impact.sh` maps a `catalog/state-paths.d/` diff to
  `catalog/state-paths.json`.
- The generated-files table (`docs/verification-map/index/tail.md`) and the
  CLAUDE.md union command carry the new path.

Test: `tests/state-paths-fragments.bh-8986-test.sh`.
