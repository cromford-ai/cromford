# catalog/prequeue-learned-seed.d/

The committed seed of the pre-queue gate's learned list (BH-6924).

`bin/prequeue-learned.sh --list` prints these suites first, then the suites it
counted from failed merge-queue batches. The conductor hook
(`bin/lib/mc-prequeue.d/learned.sh`) sends the list to the gate as `learned`.
A seed suite is always on the list: `PREQUEUE_LEARNED_MIN` and
`PREQUEUE_LEARNED_TOP` do not cut it. `--list --why` prints one
`seed<TAB><suite>` row for each seed, before the count rows.

## Format

- One file per ticket: `<ticket-key>.txt`. Do not add to another ticket's file.
- One suite path a line: `tests/<name>.sh` or `tests/mc/<name>.sh`.
- A `#` starts a comment. Blank lines are skipped.
- A line that is not a suite path is dropped. When the root has a `tests/` dir
  (a checkout), a line that names a file not in it is dropped too. A deployed
  harness has no `tests/`: there the gate's own checkout decides, and
  `bin/test-impact-gate.sh --also` drops a suite it does not have with one
  line. One stderr line counts the dropped lines.

## Adding operator-a5's batch-fail list

operator-a5 keeps `batch-fail-suites.txt`. This box cannot read it. To add it, copy
its suite lines into one new fragment here (for example `operator-a5-batch-fail.txt`)
in a PR. Do not edit `bh-6924.txt`.
