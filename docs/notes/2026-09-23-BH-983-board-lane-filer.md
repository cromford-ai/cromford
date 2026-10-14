# The in-app board lane of the child filer exists: `bin/lib/fc-board.sh`

Doc: BOARD-API-CONTRACT

## What was wrong

`file_children` (`bin/lib/file-children.sh`) dispatches to `fc_file_<lane>`, and
for a project with a board prefix in fleet.conf column 4 that lane is `board`.
No `bin/lib/fc-board.sh` existed, so the dispatch logged
`FILE_CHILDREN_UNIMPLEMENTED board` and returned 3. Every rollout on an in-app
board answered `ROLLOUT_FAILED filer unavailable` and filed nothing.

## What it does now

`fc_file_board` files the children over the board API:

1. Reads `children.txt` first. Every line must be a board key, and a record
   longer than the spec stops the run. A dry run with a record does nothing.
2. Gets the base from `fc_board_base` (the `*_API_BASE` value joined to column 4)
   and the token from the `*_INTERNAL_API_TOKEN` in the same env file.
3. Probes `GET {base}/boards`. Board `[0]` is the board it creates into. Rollout
   needs `capabilities` to be a list containing `"dependencies"`, and refuses
   with `ROLLOUT_FAILED board lacks dependencies` and zero writes otherwise, or
   when the probe fails. Decompose files anyway and leaves the dependency
   fields off.
4. Reads the parent for its `priority` and its `id`.
5. Creates each child in order at `{base}/boards/{id}/tickets`, with
   `Idempotency-Key: <kind>-<KEY>-<n>`, the title from `fc_child_title`, the
   body plus `fc_child_footer` as escaped HTML, and `parentId`/`dependsOn` when
   the capability is there. The ids go through as the board typed them.
6. Appends the key to `children.txt` and `<n>\t<key>\t<id>` to
   `children-board.tsv` right after each create answers with an `id` and a
   `key`. A failed create, or an answer missing either, stops the run with
   rc 1, and the master is not touched.
7. When this run filed anything and every child exists: one comment on the
   master listing the children (linked only where the board returned a URL),
   then a move to `in_progress`. A failure of either is a WARN; rc stays 0.

A rerun after a partial run reuses the recorded children. It takes their ids
from `children-board.tsv` and creates only the missing ones. A recorded key
with no id there stops the run rather than filing a duplicate.

## What it does not change

`bin/run-decompose.sh`'s in-app lane does not call `file_children`, so decompose
on an in-app board behaves as before. `bin/run-rollout.sh` is unchanged; a run
killed after the last create but before the park is answered `ALREADY_FILED` on
the next tick and the master is not re-parked.

## Where

- `bin/lib/fc-board.sh` (new), `tests/fc-board.bh-983-test.sh` (new)
- `docs/BOARD-API-CONTRACT.md`: the create shape with `parentId`/`dependsOn`,
  `capabilities` now required by the rollout lane, and the base path from column 4.
- `tests/file-children.bh-981-test.sh`: the callers guard now allows the board
  lane module.
