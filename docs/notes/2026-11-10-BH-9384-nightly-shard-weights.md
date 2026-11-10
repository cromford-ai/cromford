# BH-9384: the nightly shards split by measured time, not by name

Doc: ci-durations

## Cause

Run 42777389915 (main 806b8883) cancelled nightly shard 18 at its 60-minute
job timeout. Every suite it reached passed. The plan job logged
`ci-plan: sizing: count, ceil(3220/30) cap 24 (no durations file)`.

`.github/workflows/harness-nightly.yml` never fetched the shard weights. So
`suite_shard_plan` (bin/lib/suite-runner.sh) got no durations file, gave every
suite the same weight, and dealt the sorted names round-robin. Shard 18 got the
591 s, 465 s and 344 s suites together. Harness CI already fetches the weights
(BH-5518, BH-6876); the nightly (BH-6838) never got the same wiring.

## Fix

1. The nightly plan job gets `actions: read` and a
   `bin/ci-durations.sh fetch` step after the tier fetch. `CI_WORKFLOW` is the
   literal `Harness CI`, because only its green batches write
   `ci-durations-next`.
2. The plan's `bin/ci-plan.sh` step reads the file as `CI_PLAN_DURATIONS_FILE`
   with `CI_SHARD_BUDGET_S`, and the job uploads it as `nightly-durations`.
3. Each shard downloads `nightly-durations`, fails without it, re-plans with the
   same two env vars, and runs the traced scan with `SUITE_DURATIONS_FILE`.

The fetch is always rc 0. If no source answers, the file is `# source: none`,
the plan sizes by count, and the split is round-robin as before.

`tests/nightly-shard-weights.bh-9384-test.sh` pins the wiring and drives the
real split and the real `bin/ci-plan.sh --tier nightly-full` sizing.
