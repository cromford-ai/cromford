# Queue-batch attribution reads `RED: <path>` lines (BH-9516)

Doc: MERGE-CONDUCTOR

## Why

On 2026-11-11 the main-red detector froze merges for example-org/cromford
with `reason=queue`. Main was green: its own Harness CI run at `89f2fc154d60`
passed. Three independent merge-queue batches had failed
`tests/no-state-files.bh-4159-test.sh`, each on a file its own PR changes
(#9508 `bin/harness-sync.sh`, #9509 `bin/fly-pool.sh`, #9487
`bin/lib/gh-cache.sh`). That suite names the file only on a
`RED: bin/<file> has N raw state/ write(s), M at base <sha>` line.
`MRQA_FAIL_RE` in `bin/lib/main-red-queue-attr.sh` did not match that line.
`mrqa_attr` found no path, answered `untouched`, and each batch counted.

## What changed

1. `MRQA_FAIL_RE` has one more alternative, `^[[:space:]]*RED: `. It matches
   only at the start of the line content, after `_mrqa_paths` removes the gh
   job, step and timestamp prefix. It is case-sensitive. `PRED:`, `GREEN:`,
   `red:` and a mid-line `RED:` stay non-failure lines.
2. `tests/main-red-queue-attr-red-line.bh-9516-test.sh` pins it on the three
   incident batches (fixtures in `tests/fixtures/bh-9516/`), six near misses,
   two positives and a pre-fix mutant.

The verdict values, the ledger rows (kind `main_red_qattr`) and the knob
`lib.main-red-detector.main_red_queue_attr` do not change.

## Known limit

A `RED:` line from the no-state-files delta check ends with the suite's fix
hint, which names `docs/STATE-STORES.md`. That path is a candidate too. A batch
PR that changes `docs/STATE-STORES.md` and also breaks the delta check on a
file it does not change reads as `own`. The `FAIL:` alternative has the same
exposure for any path on its line.
