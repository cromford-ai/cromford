# lane-switch.bh-2407 cases go in tests/lane-switch.bh-2407-test.d/ (BH-8397)

Doc: TESTING

## What changed

- The RT1-RT3, G1/G2 and S9 sections of `tests/lane-switch.bh-2407-test.sh`
  moved, byte for byte, into three fragments in
  `tests/lane-switch.bh-2407-test.d/`: `bh-2407-1-ratchet-drop.sh`,
  `bh-2407-2-registry-a-f.sh` and `bh-2407-3-switch-migrate.sh`.
- In their place the driver has one block,
  `# >>> lane-switch.bh-2407-test.d fragments (BH-8397)`. It sources each
  regular `*.sh` in the directory once, in `LC_ALL=C` name order. No fragment
  is a FAIL. A fragment that fails `bash -n` is a FAIL and is not sourced.
- `catalog/list-files.tsv` has the row
  `tests/lane-switch.bh-2407-test.sh -> tests/lane-switch.bh-2407-test.d/`.
  `bin/list-file-lint.sh` now refuses a PR that grows the driver and adds no
  file in that directory.
- `tests/lane-switch-frags.bh-8397-test.sh` pins the split.

## Why

The driver had 12 replayed conflicts in 30 days. Sibling builds each added a
case or a name to the same lists (the `C4` switch-migrate list, the a-f
registry list) at the end of the file. One file per case removes that shared
hunk.

## What did not change

- Every case runs the same code, in the same order, with the same scratch
  paths. The driver prints `lane-switch.bh-2407: 204 passed, 0 failed` before
  and after.
- L1-L6, the `LS_MUTANT` stop and M1/M2 stay in the driver. A mutant run must
  stop after the L cases, and the block is after that stop.
- The driver with its block replaced by the three fragments is byte-identical
  to the file before the split (sha256 `da3c7060...6171`, pinned in R1).

## How to add a case

Write `tests/lane-switch.bh-2407-test.d/<ticket-key>-<name>.sh`. The rules are
in `tests/lane-switch.bh-2407-test.d/README.md`. Do not append a name to
`SWITCHES` or `C4`: S9 already checks the dry-run against every file in
`catalog/switches.d/`, so a new registry file is covered with no list edit.
