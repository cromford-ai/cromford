# New optional conductor libs go in bin/merge-conductor.d/ (BH-7453)

Doc: MERGE-CONDUCTOR

## What changed

- `bin/merge-conductor.sh` has one new block,
  `# >>> merge-conductor.d fragments (BH-7453)`. It is after the last in-file
  optional lib (`bin/lib/pr-health.sh`) and before `bin/lib/fanin.sh`. It
  sources each regular `bin/merge-conductor.d/*.sh` once, in `LC_ALL=C` name
  order. A fragment that fails to source writes one
  `merge-conductor.d: <file> failed to source (rc N); skipped this tick` line
  to the conductor log, and the tick goes on.
- `catalog/list-files.tsv` has the row
  `bin/merge-conductor.sh -> bin/merge-conductor.d/`. `bin/list-file-lint.sh`
  now refuses a PR that grows the driver and adds no file under
  `bin/merge-conductor.d/`.
- `catalog/lead-protected-paths.seed.tsv` protects `bin/merge-conductor.d/**`,
  the same as the driver and `bin/lib/mc/**`.

## Why

The driver had 12 replayed conflicts in 30 days. Most were sibling builds that
each added one optional-lib source line at the end of the same run of lines.
One file per lib removes that shared hunk.

## Where a new optional lib goes

Write `bin/merge-conductor.d/<ticket-key>-<name>.sh` (format in
`bin/merge-conductor.d/README.md`). Add only the call site to the driver. A
growth of the driver with no new fragment (for example a bug fix that adds
lines to `pr_worker`) is refused too: put that logic in a fragment or in a
`bin/lib/mc/` module.

## What did not change

- The 27 in-file optional-lib source lines stay where they are, in the same
  order. About 90 suites copy the driver into a scratch tree with no
  `merge-conductor.d/`, and there the block sources nothing.
- This change ships zero `.sh` fragments, so the conductor loads and runs the
  same code as before.
- There is no generated render and no `--check`: the driver joins the
  fragments at run time, so no committed file can go stale.
