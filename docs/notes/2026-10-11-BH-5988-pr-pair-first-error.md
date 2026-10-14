# main-red-pr-pair: a step header is not the first error (BH-5988)

Doc: main-red-pr-pair

## The bug

At 2026-10-11 01:11:01Z `bin/main-red-pr-pair.sh` paged a critical "main is
probably red" alert for #5978 and #5987. Main (0276bba5) was green. Both PRs
failed the job "Syntax + shellcheck + config integrity", and both read the
first error `##[group]Run FAIL=0`. That line is the header of the "bash -n
every script" step. `first_error_of_job` returned the first log line that
matched `MAIN_RED_ERR_RE`, and `FAIL` matched the header. So every failure of
that job had the same first error, and any two failing PRs paired. The same
false pair was open for 2309 minutes before it resolved on 2026-10-10 18:50Z.

The real errors: #5978 `rules-pack rc=0 fast-lints rc=1 budget rc=0`, #5987
`rules-pack rc=1 fast-lints rc=0 budget rc=0`.

## What changed

1. `first_error_of_job` reads the runner's own lines first:
   - The LAST `##[error]` line wins.
   - A generic `##[error]Process completed with exit code N.` reads as the
     line before it in the same step. If the step printed nothing, it reads
     `Run <step>: Process completed with exit code N.`
   - Any other `##[error]` (an `::error::` annotation) is read as written.
   - `MAIN_RED_ERR_RE` applies only to a log with no `##[error]` line.
   - Marker lines (`##[group]`, `##[endgroup]`, `##[notice]`, `##[warning]`,
     and the rest) are skipped. Everything inside a `##[group]Run ...` block
     (the echoed script, `shell:`, `env:`, `with:`) is skipped.
   The output never starts with `##[`. The rc contract (0 found, 1 read
   failed, 2 read ok and nothing found) does not change.
2. A ledger row in `state/main-red/pr-errors/<owner>-<repo>/<head>.tsv` whose
   column 2 starts with `##[` was written by the old parser. `mrp_row_stale`
   finds it, and the lane reads that head again once. Without this the old
   rows stayed terminal for `MAIN_RED_PAIR_LEDGER_DAYS` (14) and the false pair
   stayed open after the deploy. `--explain` reads the head again into its
   scratch dir and does not touch the ledger. A re-read that fails deletes the
   row, the head counts as unknown, and no resolve is sent that tick.

## Last `##[error]`, not first

The ticket asked for the first `##[error]`. This change uses the last one.
The merge-reuse step (`bin/ci-merge-reuse.sh`) is `continue-on-error: true`.
In #5987 it wrote `##[error]Process completed with exit code 2.` for
`bad args: MR_BEFORE is empty`, and the job went on. The first `##[error]`
named a step that did not fail the job. Two PRs that both hit that condition
and then fail for different reasons would pair again. In a fail-fast job the
steps after the failing step are skipped, so the last `##[error]` is the step
that failed the job.

## Test

`tests/main-red-pr-pair-first-error.bh-5988-test.sh`. The two fixture logs in
`tests/fixtures/bh-5988/` are reconstructions of the two job logs, not
downloads (see the README there).
