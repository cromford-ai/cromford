# New optional enqueue libs go in bin/lead-review-enqueue.d/ (BH-8396)

Doc: LEAD-REVIEW

## What changed

- `bin/lead-review-enqueue.sh` has one new block,
  `# >>> lead-review-enqueue.d fragments (BH-8396)`. It is after the last
  in-file optional lib (`bin/lib/console-qa-gate.sh` and its `CQG_HREPO` line)
  and before `cqg_gate_on()`. It sources each regular
  `bin/lead-review-enqueue.d/*.sh` once, in `LC_ALL=C` name order.
- A fragment that fails `bash -n` writes one
  `lead-review-enqueue.d: <file> does not parse; skipped this tick` line to
  `logs/lead-review-enqueue.log`, and none of its lines run. A fragment that
  fails on source writes one
  `lead-review-enqueue.d: <file> failed to source (rc N); skipped this tick`
  line. The tick goes on in both cases.
- `catalog/list-files.tsv` has the row
  `bin/lead-review-enqueue.sh -> bin/lead-review-enqueue.d/`.
  `bin/list-file-lint.sh` now refuses a PR that grows the driver and adds no
  file under `bin/lead-review-enqueue.d/`.
- `catalog/lead-protected-paths.seed.tsv` protects
  `bin/lead-review-enqueue.d/**`, the same as the driver.
  `tests/fixtures/lead-protected-paths.bh-4148.txt` has the same glob: case F
  of `tests/lead-authority-db.bh-4148-test.sh` compares the seed globs with
  that fixture.

## Why

The driver had 12 replayed conflicts in 30 days. Sibling builds each added
lines to the same run of optional-lib source lines. One file per lib removes
that shared hunk. This is the same shape as `bin/merge-conductor.d/`
(BH-7453) and `bin/blocked-resolver.d/` (BH-7450).

## Where a new optional lib goes

Write `bin/lead-review-enqueue.d/<ticket-key>-<name>.sh` (format in
`bin/lead-review-enqueue.d/README.md`). Add only the call site to the driver.
A growth of the driver with no new fragment is refused too: put that logic in
a fragment or in a `bin/lib/` module.

## What did not change

- The in-file optional-lib source lines stay where they are, in the same
  order. Their side effects (`LD`, `LCW`, `PSC`, `RT`, `CQG`) depend on that
  order.
- This change ships zero `.sh` fragments, so the enqueue loads and runs the
  same code as before.
- There is no generated render and no `--check`: the driver joins the
  fragments at run time, so no committed file can go stale.
- An open PR that grows the driver with no fragment (for example #8135,
  BH-8079) goes red on `bin/list-file-lint.sh` once this merges. Its fix is a
  fragment file or a `bin/lib/` module.
