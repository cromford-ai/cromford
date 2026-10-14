# Pre-queue gate: learned suites, the trace, and fresh against main (BH-6335)

Doc: MERGE-CONDUCTOR

## What happened

On 2026-10-12, 106 of 148 merge-queue batches had a failed check. The failed
batches ran about 2,000 minutes. The pre-queue gate (BH-4545,
`.github/workflows/prequeue-gate.yml`) did not stop the cause:

- A PR broke a whole-tree suite that the impact map does not select for its
  diff. #5920 put a raw flag test in `bin/pool-cap.sh`; `flag-callsites-pool`
  G1 failed 4 batches.
- A PR's suite wrote outside the temp roots (#6039). Only the CI check
  `Tests cannot touch a real harness` ran that trace, in the batch.
- A green verdict was reused while it was under 30 minutes old, however far
  main had moved. Main took 62 commits that day, 11 in the peak hour.

## What changed

1. **Three invariant rows.** `catalog/prequeue-invariants.tsv` has
   `flag-callsites-pool`, `mc-split-layout` and `gh-rest-no-subshell` (17 rows).
   `lanes-registry` and `determinism` were rows already. Each new row is green
   in CI's shape (no `/root/harness`).
2. **Learned suites.** A new hub lane, `bin/prequeue-learned.sh --refresh`
   (`cron/lanes/729-prequeue-learned.cron`, :23 and :53), reads each failed
   merge-queue batch run of `harness-ci.yml` once and keeps its failing suites
   in `state/prequeue-learned/runs/<run_id>`. `--list` prints the suites that
   failed at least `PREQUEUE_LEARNED_MIN` (20) batches in
   `PREQUEUE_LEARNED_DAYS` (7) days, at most `PREQUEUE_LEARNED_TOP` (10).
   The conductor hook `bin/lib/mc-prequeue.d/learned.sh` sends them as the
   workflow input `learned`. The gate runs them first, outside the cap
   (`bin/test-impact-gate.sh --also`).
3. **The trace.** With the merge-conductor knob `MC_PREQUEUE_TRACE=1` (the
   default) the hook sends `trace=1`. The workflow runs the gate with
   `--runner traced --trace-hits`: each suite runs under
   `bin/test-trace-safety.sh --gate`. A hit is `red ... why=trace`, with the
   hit suites named first. A tracer that cannot run is `could-not-run`.
4. **Fresh against main.** In `pq_resolve`, a reused non-red verdict for an
   older main counts only when that main is at most
   `MC_PREQUEUE_FRESH_COMMITS` (3) commits behind the current main
   (`pq_main_behind`, one compare read per pair). Otherwise the conductor
   dispatches the gate for the current main and holds the row. The log line is
   `PREQUEUE reuse ... -> stale-commits behind=<n|unreadable> k=<K>`. A red
   parks at any distance, as before.

A malformed `learned` or `trace` input is `could-not-run` with
`why=bad-learned` or `why=bad-trace`. With both inputs empty the gate argv is
the same as before.

## Not in this change

- "A merge-queue ejection voids an older green verdict on the same head" is
  PR #6182 (BH-6161, `PQ_MIN_AT`). Case P4 of
  `tests/prequeue-gate-learned-suites.bh-6335-test.sh` pins it and skips with a
  note until that code is on the tree.
- Body item 4 (run on the pool, in parallel per PR) was already true: the
  workflow runs on `vars.CI_RUNNER`, one run per (PR, head, main).

## Operator checks

1. Run `bin/prequeue-learned.sh --list --why` on the hub.
2. Read `logs/prequeue-learned.log`. After the first ticks, `recorded=` must be
   above 0.
3. Run `grep stale-commits logs/merge-conductor.log` and
   `grep 'why=trace' logs/merge-conductor.log`.

Tests: `tests/prequeue-gate-learned-suites.bh-6335-test.sh`,
`tests/prequeue-learned.bh-6335-test.sh`.
