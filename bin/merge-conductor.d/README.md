# bin/merge-conductor.d/ — optional conductor libs, one file each (BH-7453)

A new optional lib for `bin/merge-conductor.sh` goes here as its own file,
`<ticket-key>-<name>.sh` in lower case (for example `bh-7612-foo-gate.sh`;
the name matches `^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$`). Do not
add one more `[ -r "$H/bin/lib/<x>.sh" ] && . ...` line to the driver:
`bin/list-file-lint.sh` refuses a PR that grows the driver and adds no file
here (`catalog/list-files.tsv`).

A fragment is a sourced bash file. It defines functions, and it may set
top-level variables, add `command -v x || x() {...}` fallbacks, or source a
`bin/lib/` file, as the in-file libs do. It must not define a name that the
driver, `bin/lib/merge-conductor-lib.sh` or a `bin/lib/mc*` lib defines, and
two fragments must not define the same name. It must never `exit`.

The driver sources every regular `*.sh` file in this directory once, in
`LC_ALL=C` name order, in the `# >>> merge-conductor.d fragments (BH-7453)`
block. That block is after the in-file optional libs and before `fanin.sh`.
Other files (this README, `*.sh~`, subdirectories) are not sourced. If a
fragment fails to source, the conductor writes one `merge-conductor.d: <file>
failed to source (rc N)` line to its log and goes on with the tick.

A fragment only defines things. The driver still needs a call site, for
example `command -v foo_gate >/dev/null 2>&1 && foo_gate ...` in `pr_worker`.
`tests/merge-conductor-frags.bh-7453-test.sh` checks the name format, `bash -n`
and the name rules over this directory.
