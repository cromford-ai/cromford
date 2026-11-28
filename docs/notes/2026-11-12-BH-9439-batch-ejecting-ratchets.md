# The builder gate runs the batch-ejecting ratchets; the red-batch report reads the group gate (BH-9439)

Doc: MERGE-CONDUCTOR

## Why

From 2026-10-27 to 2026-11-10, 114 of 303 cromford merge-queue batches
were red (38%). The failing suites (`tests/no-state-files.bh-4159-test.sh` in
37 batches, `tests/no-flag-files.bh-4154-test.sh` in 12, and eight more at 6
to 10) were selected by the builder gate only as `full` (rank 7). The cap of
80 cut them, so the batch was their first run on the PR's tree.
`bin/ci-batch-red-report.sh` wrote `gate <pr> ? -` for almost every red batch
after BH-8327 moved the pre-queue gate to `prequeue-group-gate.yml`, so its
A/B/C split had no data.

## What changed

1. `catalog/ci-batch-regression.d/bh-9439.txt` gives the 10 suites a `*`
   row. A `*` row ranks `regression` (1), inside the cap. The selector also
   prints every `*` map row as `always`, so the existing fresh-main pass
   (BH-6459) already runs these suites on HEAD merged with main. No change to
   `fresh_prep` was needed. `tests/test-impact-ratchets.bh-9439-test.sh` F1
   pins it.
2. `bin/ci-batch-red-report.sh` also lists the `prequeue-group-gate.yml` runs
   (`prequeue group=g<hex> main=<40>`). `gate_line` finds the member's job
   `gate (<pr>, <head40>) / gate` in the newest group run before the batch, at
   most `CI_BATCH_RED_GROUP_SCAN` (20) runs back, and takes the newer of that
   and the per-PR run. The verdict parse reads the ledger shape
   `##[notice]<v> main=<40> head=<40>`. The echoed script line is not a
   verdict. A new line goes to `logs/ci-batch-red-gate.log` on each tick:
   `ci-batch-red-gate: repo=<r> days=<d> red=<n> gate_unread=<u> gate_unread_pct=<p|->`.
3. `bin/impact-learn.sh regression` reads the report's records. A suite that
   turned `IMPACT_LEARN_REGRESSION_MIN` (3) or more batches red in
   `IMPACT_LEARN_REGRESSION_DAYS` (7) days, with every member gate readable
   and none running it, gets `catalog/ci-batch-regression.d/learned-<16hex>.txt`.
   `bin/impact-learn-lane.sh` step 7c writes these files in its one PR. They
   count against `IMPACT_LEARN_MAX_EDGES`. MIN 0 turns step 7c off.

## Known limits

- Old records keep their `?` gate lines. The learner sees few suites until 7
  days of new records exist.
- Learned regression rows do not expire. A person deletes one by hand.
- Each new fragment in `catalog/ci-batch-regression.d/` costs one
  full-corpus batch when it lands (the escalate row).
