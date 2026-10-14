# Suite fingerprint v2: a helper is an input of its consumers, and the nightly run never reuses (BH-6406, slice C1 of BH-6371)

Doc: CI-RUNNERS, MERGIFY

## Why

The suite fingerprint (`bin/lib/suite-fingerprint.sh`, BH-5366) hashed every
`tests/lib/` and `catalog/` path into `infra_hash`. `ti_inputs` wrote them all
as `@infra`, because `ti_infra_re` contains `^tests/lib/|^catalog/`. So one
helper edit moved all 2,147 fingerprints, and a merge-queue batch that changed
a helper could reuse no suite. On the real tree at 5df5fbfe, 767 paths were
`@infra`: 55 helpers and 700 catalog files.

The reuse line did not name the fingerprint. A run that skipped a suite gave
no way to check the hash it matched.

`--tier nightly` never asked the ledger, but a shard branch subtracted
`CI_PLAN_REUSED_FILE` with no check. A nightly run handed that variable would
skip suites.

## What changed

**Fingerprint v2.** `bin/test-impact.sh inputs`:

- adds a `<suite>\t<helper>` row for every `tests/lib/` helper that a helper
  the suite names reaches. `ti_testlib_edges` gives the reach. It is the
  downward form of the BH-6371 helper closure: same files, same basename rule,
  same comment rule.
- writes `@infra` only for (`ti_inputs_infra`):
  1. a path `ti_infra_core_re` matches;
  2. a `tests/lib/` path that no suite reaches (no map or helper row names it);
  3. a `catalog/` path with no specific map row;
  4. a `tests/lib/` or `catalog/` path that the tree's own
     `catalog/ci-batch-escalate.tsv` escalates (`tests/lib/scratch.sh`,
     `catalog/test-tiers.tsv` and the other global inputs).
- never writes `@infra` for a `*.md` under `tests/lib/` or `catalog/`.
- never reads `CI_BATCH_ESCALATE_TSV` for this. The fingerprint is a function
  of the tree.
- fails closed. If `bin/lib/ci-batch-escalate.sh` cannot be sourced, or the
  rules file cannot be read, every `tests/lib/` and `catalog/` path is
  `@infra`. That is the v1 set.

The invariant: a path moves a suite's fingerprint exactly when the merge-queue
batch select (`TI_BATCH_SELECT=1`) of that path selects the suite, or when the
path is `@infra`. A path the batch select calls `unmapped path` is `@infra`.

`bin/lib/suite-fingerprint.sh` writes `suite-fp v2` as the first line of the
canonical text. It also adds `bin/lib/ci-batch-escalate.sh` and
`catalog/suite-reuse-never.tsv` to its explicit infra list.

On the real tree at 5df5fbfe plus this change, 19 paths are `@infra`: one
helper (`tests/lib/scratch.sh`) and six catalog files. `bin/test-impact.sh
inputs` took 15.0 s before and 16.6 s after on the build box.

**The reuse line names the fingerprint.** `bin/ci-plan.sh` prints
`reuse: reused <suite> from <run_id> (<d>s) fp <64-hex>`. The plan job takes
the fp from its own `fingerprints.tsv`. A shard takes it from the
`fingerprints.tsv` beside `CI_PLAN_REUSED_FILE`. Without that file, the line
ends in `fp -`.

**The nightly run never reuses.** With `--tier nightly` or
`CI_EVENT=schedule`, `bin/ci-plan.sh` ignores `CI_PLAN_REUSED_FILE`. The list
stays whole, the run prints `reuse: off: nightly never reuses`, and the
outputs say `reuse=off: nightly never reuses` and `reused=0`.
`reuse_eligible` refuses both events explicitly.

## Operator facts

- v1 ledger rows stop matching at once. The first runs after the merge reuse
  nothing until v2 rows are recorded.
- CI reuse saves 0 suites until the repo variable `SUITE_LEDGER_URL` and the
  secret `SUITE_LEDGER_TOKEN` are set. Without them the plan job prints
  `reuse: off: no credential`.
- Known gap, accepted from the BH-6059 batch select: a catalog file that one
  suite names, and that another suite reads only through a `bin/` script, does
  not move the second suite's fingerprint.

## Tests

- `tests/suite-fingerprint-v2.bh-6406-test.sh` (V0-V9): which edit moves which
  fingerprint, the `inputs` rows, the fail-closed cases, and the v2 header.
- `tests/ci-plan-reuse-full.bh-6406-test.sh` (T4-T5c): the real `ci-plan.sh`,
  `suite-reuse.sh` and worker ledger. A helper edit reuses the suites that do
  not reach it, each line carries its fp, and the nightly run never reuses.
- `tests/ci-plan-reuse.bh-5368-test.sh` C1 now pins the fp on the reused line.
