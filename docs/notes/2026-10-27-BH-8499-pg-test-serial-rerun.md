# The pool suite on a small disk: most-room root, one ENOSPC rerun, serial run (BH-8499)

Doc: docs/verification-map/entries/BH-8499.md

## The problem

project-6-os builds TK-1692 and TK-1836 ran their suite on the throwaway
Postgres (BH-5962) on a pool machine with a small disk. The suite seeds large
tables, and Postgres ran out of space. BH-8175 made a disk fault
`HARNESS_EXIT: could-not-run`, not a red suite. But then no suite gave a
verdict, and the review had no evidence from this box.

## What changed

1. `pgt_root` (`bin/lib/pg-test.sh`) picks the candidate root with the MOST
   free MB, at or above `pool_test_postgres_min_free_mb`. Before, it picked the
   first root with enough. A tie keeps the list order, so `/dev/shm` stays
   first when equal.
2. An ENOSPC red reruns the failed files once. `HARNESS_SUITE_RUN`
   (`bin/lib/rb/gates.sh`) reads the `FAIL <file>` lines of the red run
   (`pgt_failed_files`) and runs each file alone on its own fresh cluster
   (`pgt_run_files`). It does this only when:
   - the run's rc is exactly 1 (a timeout can hide files it never named);
   - the run used the harness Postgres;
   - the run was not serial;
   - the output names 1 to `pool_test_pg_rerun_max_files` real test files;
   - every `FAIL <path>` line names a real test file in the repo. One FAIL line
     that names anything else (not a `.test.`/`.spec.` file, missing, a
     symlink, absolute, `..`) stops the rerun, because the rerun cannot run
     that file. The record stays `could-not-run`, as before BH-8499.

   Every file green = `HARNESS_EXIT: 0`. A red file = its rc. Else (ENOSPC
   again, a timeout, a file not run) = `could-not-run`. A rerun never reruns.
   `HARNESS_DISK: ENOSPC` stays in the file as the first run's record.
3. `pool_test_postgres_serial=1` runs a SELECTED suite one file at a time, each
   on its own fresh cluster, in place of the single run. A full run names no
   files, so it runs as before and says `HARNESS_PG_SERIAL: off (...)`.

The fix round and the moved-head rerun call the same `HARNESS_SUITE_RUN`, so
they get the rerun too.

## New suite-file lines

- `HARNESS_PG_FILE: <file> (rc=N)`, `(rc=N, ENOSPC)` or `(not run: <why>)`
- `HARNESS_PG_RERUN: <n> failed file(s) after ENOSPC, ...` then
  `HARNESS_PG_RERUN: green | red (rc=N) | could-not-run (<file>: <why>)`
- `HARNESS_PG_SERIAL: on (...) | off (...)` then
  `HARNESS_PG_SERIAL: green | red (rc=N) | could-not-run (...)`

`pipeline.log` gets `HARNESS-VERIFY <phase> rerun: ...` and
`HARNESS-VERIFY <phase> serial (...)` lines. No reader of `HARNESS_EXIT`
changes.

## Knobs (fly-pool lane, rows `lane.fly-pool.<project>.<name>`)

| Knob | Default | Meaning |
|---|---|---|
| `POOL_TEST_POSTGRES_SERIAL` | 0 | 1 = a selected suite runs one file at a time |
| `POOL_TEST_PG_RERUN_MAX_FILES` | 20 | the most files an ENOSPC rerun runs; 0 = no rerun |
| `POOL_TEST_PG_SERIAL_BUDGET_S` | 1500 | the total seconds of one serial run or rerun |

No project row is seeded. Serial stays off until an operator sets the row.

## Not in this change

The pool machine rootfs knob (ticket item 3) and the rebuilds of project-6
#1692 and #1836 are slice C1 of BH-8499.

Suite: `tests/pool-test-postgres-serial.bh-8499-test.sh`.
