# bin/lead-review-enqueue.d/ — optional enqueue libs, one file each (BH-8396)

A new optional lib or helper for `bin/lead-review-enqueue.sh` goes here as its
own file, `<ticket-key>-<name>.sh` in lower case (for example
`bh-8400-foo-hold.sh`; the name matches
`^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$`). Do not add one more
`. "$H/bin/lib/<x>.sh" 2>/dev/null || true` line to the driver:
`bin/list-file-lint.sh` refuses a PR that grows the driver and adds no file
here (`catalog/list-files.tsv`).

A fragment is a sourced bash file. It defines functions, and it may set
top-level variables, add `command -v x || x() {...}` fallbacks, or source a
`bin/lib/` file, as the in-file libs do. It must not define a name that the
driver or a lib it sources defines (for example `request`, `log`,
`cqg_gate_on`), and two fragments must not define the same name. It must never
`exit`.

The driver sources every regular `*.sh` file in this directory once, in
`LC_ALL=C` name order, in the `# >>> lead-review-enqueue.d fragments (BH-8396)`
block. That block is after the in-file optional libs (the console-qa-gate lib)
and before `cqg_gate_on()`. Other files (this README, `*.sh~`, subdirectories)
are not sourced. A fragment that fails `bash -n` writes one
`lead-review-enqueue.d: <file> does not parse; skipped this tick` line to
`logs/lead-review-enqueue.log`, and none of its lines run. A fragment that
fails on source writes one `lead-review-enqueue.d: <file> failed to source
(rc N); skipped this tick` line. The tick goes on in both cases.

A fragment only defines things. The driver still needs a call site, for
example `command -v foo_hold >/dev/null 2>&1 && foo_hold ...` in the gate that
uses it. `tests/lead-review-enqueue-frags.bh-8396-test.sh` checks the name
format, `bash -n` and the name rules over this directory.
