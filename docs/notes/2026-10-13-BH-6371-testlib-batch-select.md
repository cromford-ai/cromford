# A tests/lib helper or an add-only rules diff selects in a merge-queue batch (BH-6371, slice C0)

Doc: MERGIFY

## Why

A merge-queue batch that changed any file under `tests/lib/` ran the whole
corpus (2048 of 2147 suites, 8 shards). Two rules caused it:

- `catalog/ci-batch-escalate.tsv` had a blanket `tests/lib/	escalate` row.
- `bin/test-impact.sh` had `^tests/lib/` in `ti_infra_core_re`, the infra list
  a batch select reads.

A batch that only added one `spa` or `worker` row to
`catalog/ci-batch-escalate.tsv` also ran the whole corpus, because the
`catalog/ci-batch-escalate.tsv` escalate row matched any diff to the file.
These two causes gave all 12 full-corpus batches in the ticket's table.

## What changed

- `bin/test-impact.sh`: `^tests/lib/` moved from `ti_infra_core_re` to
  `ti_infra_re`. The PR `ci-select`, the builder gate and `ti_inputs` (the
  suite fingerprint) read `ti_infra_re`, so they see the same infra set as
  before. Only a batch select (`TI_BATCH_SELECT=1`) changes.
- In a batch select, a changed `tests/lib/<helper>` selects through its
  HELPER CLOSURE (`ti_testlib_closure`). The closure is the helper, plus every
  `tests/lib/` file that names the basename of a file already in the closure
  on a line that is not a comment, until no file is added. Example:
  `tests/lib/rb-all.sh` also selects the 55 suites that reach it only through
  `tests/lib/fixture-harness.sh`.
- If no map row names a file of the closure exactly, the batch runs the
  corpus with `escalation=unmapped path tests/lib/<helper>`. The `tests/lib/`
  and `tests/` directory rows do not count as a consumer, because they match
  every helper. They still select their suites.
- `tests/lib/*.md` never goes full in a batch.
- `catalog/ci-batch-escalate.tsv`: the `tests/lib/` row is now
  `tests/lib/scratch.sh`. An escalate row under `tests/lib/` is the list of
  GLOBAL helpers. `tests/lib/scratch.sh` is the only one: 2109 of 2147 suites
  source it.
- `bin/lib/ci-batch-escalate.sh`: new `cbe_add_only <diff-file>`. It reads
  `git diff -U0` output of the rules file. It is rc 0 only when there is no
  removed line, at least one added row, and each added line is blank, a `#`
  comment, or `pattern<TAB>kind<TAB>why` with a non-empty pattern and kind
  `escalate`, `spa` or `worker`. It prints the added kinds.
- `bin/ci-plan.sh` `batch_select`: for the path
  `catalog/ci-batch-escalate.tsv`, it writes
  `git diff --no-renames -U0 TI_BASE HEAD` of that file and asks
  `cbe_add_only`. On rc 0 the path does not escalate. It selects through the
  map, and the reason carries `escalation rows added only (<kinds>)`. An
  added `spa` row sets `spa=1`. An added `worker` row sets `worker=1`.
  A removed or changed row, an added `allow` row, a malformed row, a
  comment-only diff, an empty diff or a diff that fails still escalate with
  `selection input: catalog/ci-batch-escalate.tsv`.

## New reason strings

- `escalation=unmapped path tests/lib/<helper>`: a changed helper that no
  suite reaches.
- `reason=…; escalation rows added only (spa,worker)`: an add-only rules diff
  that stayed batch-selected.

## Not changed

- An ordinary PR and the builder gate still answer
  `full: infra change (tests/lib/<helper>)`.
- The suite fingerprint (`bin/lib/suite-fingerprint.sh`) still hashes every
  `tests/lib/` and `catalog/` path into `infra_hash`.

## Left to child tickets

- C1: ticket scope 3. Fingerprint v2 without the blanket `tests/lib/` and
  `catalog/` infra, with the helper closure, and a reuse log line.
- C2: ticket scope 4. pipeline-health counts of full and batch-selected
  batches per day.

Test: `tests/ci-plan-testlib-select.bh-6371-test.sh`.
