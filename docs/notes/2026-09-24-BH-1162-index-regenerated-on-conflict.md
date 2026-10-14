# docs/notes/INDEX.md conflicts resolve by regeneration

Doc: MERGE-CONDUCTOR

## What changed

When the conductor merges main into a PR and `docs/notes/INDEX.md` conflicts,
it now re-runs `bin/render-doc-index.sh` over the merged tree and stages what
that writes. It no longer unions the two sides.

The table of paths is the new `config/regenerated-paths.conf`, written as
`<path><TAB><command>` with literal paths only. Its one entry is
`docs/notes/INDEX.md` mapped to `bin/render-doc-index.sh`. The same table is
compiled into `bin/lib/mc/rebase.sh` as `MC_REGENERATED_PATHS_DEFAULT` for pool
images that bake `bin/` without `config/`. `mc_resolve_generated` checks it
first, so this class needs no ticket key in the path or the branch.
`mc_resolve_conflicts` holds these paths back and handles them after every
other conflicted path is staged. That way the generator never reads a note that
still has markers in it.

A path in this class stays a REAL conflict, with its markers restored, in these
cases:

- another path in the same directory is still unmerged
- it is a modify/delete
- the generator is missing from the merged tree
- the generator exits non-zero
- the generator writes markers

The failures that happen after the generator starts log a line to
`merge-conductor.log`. The path is never handed to the `*.md` union arm.
`bin/lib/guard-silenced.sh` counts `config/regenerated-paths.conf` as a guard
file, like `config/generated-paths.conf`.

`bin/render-doc-index.sh --check [notes-dir] [out-file]` renders to a temp file
and compares the result with the index. It never writes the index. rc 0 means in
sync, rc 1 means stale or missing (it prints a short diff), and rc 2 means the
check could not run.

## Why

Two PRs that each add a note and re-render conflict on INDEX.md and nothing
else. That is how #1097 got rebased twice in an hour. The path has no ticket
key, so it fell to the union arm, which produced a "sorted" index with rows out
of order or listed twice. the operator's ruling on BH-1162 (2026-09-24): "regenerate on
conflict. Do not use `merge=union`."

## What did not change

- There is no `.gitattributes` entry, and INDEX.md is still committed.
- INDEX.md is not in the `## Generated files` table, so a clean merge does not
  re-render it, and batch-resolve trains are unaffected.
- `--check` is not wired into CI yet. The committed index is already behind the
  notes on main, and feature PRs do not re-render it (D37), so the gate would go
  red everywhere. Wiring it in is a separate decision.
