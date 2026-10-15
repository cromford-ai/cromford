# catalog/ci-batch-regression.d/ — the batch-fail regression list (BH-6838)

A suite that failed a merge-queue batch, and that the PR's own checks did not
run, gets a row here. The row makes the suite run before the batch:

- `bin/test-impact.sh` reads every `*.txt` here as map edges of kind
  `regression`. `bin/test-impact-gate.sh` ranks `regression` with `reads`
  (rank 1), so the builder gate runs the suite and never leaves it to CI by
  the cap.
- `bin/ci-plan.sh` adds every row the batch's diff touches AFTER the tier
  step, so a suite with a `nightly` tier row still runs in the batch. A
  quarantined suite and a suite not in the tree are not added.

## Format

One file per ticket, `<ticket-key>.txt` (never append to another ticket's
file). One row per line, tab separated:

```
<suite>	<paths>
```

- `<suite>` is `tests/<name>.sh` or `tests/mc/<name>.sh`.
- `<paths>` is `*` (every PR and every batch) or a comma list of files,
  `<dir>/` prefixes and globs. A row runs the suite when the diff touches one
  of them.
- A `#` line is a comment. Put the batch number and the failure class above
  each row.

A row whose suite is not in the tree fails
`tests/ci-plan-nightly-split.bh-6838-test.sh` (case A4). A fragment that cannot
be read fails the map, so the selection is the whole corpus.

`catalog/ci-batch-regression.d/` has an escalate row in
`catalog/ci-batch-escalate.tsv`: a batch that changes this list runs the whole
corpus. This is a known cost: each new fragment costs one full-corpus batch
when it lands. Put the rows a replay finds into one fragment, not one per row.
