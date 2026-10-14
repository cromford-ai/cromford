# One command registers a box in every box list (BH-5747)

Doc: ADDING-A-BOX, OPERATOR-SETUP

## What changed

- `bin/box-register.sh` writes one box into the nine box lists, or takes it
  out (`--retire`). The default is a dry run; `--apply` writes. The
  `catalog/lanes.d/trap-eval.json` edit is a separate step (`--trap-eval`) on
  its own branch, because of BH-1965.
- `bin/box-lists-check.sh` compares every box list with `fleet.conf` in both
  directions. Exit 0 is no finding, 1 is findings, 2 is an unreadable input.
- `bin/fleet-conf.sh --box-ids` prints the box ID of every active row.
- The `bin/cost-rollup.sh` overage loop reads `fleet-conf.sh --box-ids`. Its
  literal box list is gone, so a new box is collected with no edit.
- `tests/box-console-commands-lane.bh-2528-test.sh` (A10) and
  `tests/tmp-sweep.bh-5007-test.sh` (A13) read the box list from `fleet.conf`.

## Why

PR #5632 added one box by hand. It changed 47 files, and a missed list fails
silently: a box that pings nobody, or a meter that is never collected.

## How to use it

`docs/ADDING-A-BOX.md` has the order of steps, the lists and the exit codes.
