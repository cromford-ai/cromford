# tests/lane-switch.bh-2407-test.d/ — lane-switch cases, one file each (BH-8397)

A new case for `tests/lane-switch.bh-2407-test.sh` goes here as its own file,
`<ticket-key>-<name>.sh` in lower case (for example `bh-8400-foo-off.sh`; the
name matches `^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$`). Do not add
lines to the driver, and do not append a name to a list in another fragment:
`bin/list-file-lint.sh` refuses a PR that grows the driver and adds no file
here (`catalog/list-files.tsv`).

The driver sources every regular `*.sh` file in this directory once, in
`LC_ALL=C` name order, in the main shell, from its
`# >>> lane-switch.bh-2407-test.d fragments (BH-8397)` block. That block is
after M1/M2, so a mutant run (`LS_MUTANT=1`) never reaches a fragment. Other
files (this README, `*.sh~`, `*.sh.bak`, subdirectories, a dangling symlink)
are not sourced.

A fragment:

- uses the driver's helpers and state: `ok`, `bad`, `eq`, `$T`, `$DIR`, the
  `srt_*` helpers of `tests/lib/switch-ratchet-tree.sh`, and the counters;
- keeps its scratch files under `$T/<fragment-name>/`;
- never calls `exit` (that ends the whole suite before its summary line);
- never reads a variable another fragment sets. One exception is kept from the
  split, so that the split moved bytes and changed nothing:
  `bh-2407-3-switch-migrate.sh` reads `SWITCHES` from
  `bh-2407-2-registry-a-f.sh`. Their names sort them next to each other.

Fail-closed: a directory with no fragment is a FAIL, and a fragment that fails
`bash -n` is a FAIL and is not sourced. A fragment's last exit status is not a
verdict; its own `ok`/`bad` lines are.

`tests/lane-switch-frags.bh-8397-test.sh` checks the name format, `bash -n`,
the sourcing order and the fail-closed rules.
