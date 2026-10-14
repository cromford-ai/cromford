Doc: BOARD-API-CONTRACT

# The in-app decompose lane files its own children and writes their dependencies (BH-3965, part 3 of BH-3946)

## What changed

- `bin/run-decompose.sh` no longer asks the model to POST the children on an
  in-app board. The model writes `$BUILD/children.json` only, the same checks
  the issues lane runs refuse a bad one (2-5 children, title and body, the
  contract field, the 2-level chain cap, an `## Observable outcome` in every
  body), and `file_children` hands it to `bin/lib/fc-board.sh`. A
  `children.json` already in the build dir is reused with no model call, on a
  real run and on `DECOMPOSE_DRY_RUN=1`.
- `fc_file_board` reads `capabilities` on board `[0]` for decompose too. On a
  board that advertises `"dependencies"` each sibling's create carries
  `parentId` and `dependsOn` = [the contract's id, then the ids of its `after`
  siblings], and its description has no `Blocked-by:` line. On a board that
  does not, there are no dependency fields and the description carries
  `Blocked-by: <contract key> (hard)[, <sibling key> (hard)…]` with the keys the
  create calls returned, never a `<KEY>.<n>` title label.
- `fc_child_footer` writes a sibling's `Blocked-by:` line only when it is handed
  one. The issues lane always hands one, so its bytes are unchanged.

This supersedes the `docs/BOARD-API-CONTRACT.md` sentence "The decomposer's
in-app lane does not read `capabilities` either."

## The switch

`decompose-board-filer-off` (`lane_switch … file`: the `switch.decompose-board-filer-off`
settings row, then `flags/decompose-board-filer-off`) puts back the old path:
the model files the children, the BH-866 label re-map turns `<KEY>.<n>` lines
in `children.txt` into board keys, and the script parks the master. Registered
in `catalog/switches.d/decompose-board-filer-off.json`.

## How to check it

```bash
HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-inapp-deps-test.sh
DECOMPOSE_DRY_RUN=1 bin/run-decompose.sh <project> <ticket-id> <KEY> /tmp/dec-dry   # with a hand-written /tmp/dec-dry/children.json
```

The dry run sends nothing and prints every curl. It assumes the board has the
capability, so the printed sibling bodies carry no `Blocked-by:` line.
