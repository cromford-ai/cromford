# A job that dies at its timeout is a repo problem, not a flake (BH-3775)

Doc: MERGE-CONDUCTOR

**Status (2026-10-01, BH-3784).** This note ships with the CONTRACT slice
only: the lib, its knobs, the ledger and firing-file formats, the `cit_assess`
entry point with three fail-open stubs, and the call from the flake ladder.
With only this slice merged the conductor behaves exactly as before. The scan,
the rekick and the budget/alert land with the later BH-3775 children, and
nothing below that names them is live until they do.

## Why

15 project-4 PRs sat in `WAIT_CI` for up to 9 days. A required check
(`Unit tests (incl. Inner Circle parity guard)`, `timeout-minutes: 10`) died at
its limit on 29 of 40 runs. GitHub reports a job timeout as `cancelled`, so the
BH-636 flake ladder in `bin/merge-conductor.sh` re-ran each PR once and then
raised one `CI_FLAKE_TWICE` per PR. Nobody saw the repo-level cause: one check
whose limit is too tight for the work it now does.

## The rule

A dead job whose duration reaches its workflow's `timeout-minutes` (within
`MC_CI_TIMEOUT_SLACK_S`) is a TIMEOUT, not a killed runner. When the same check
times out on enough PRs and a large enough share of its recent runs, re-running
it buys nothing: the repo needs its limit raised. The budget withholds those
reruns and pages once for the repo instead of once per PR. That decision lives
in the later slices. This slice only gives it a place to stand.

## What changed (this slice)

1. **`bin/lib/mc-ci-timeout.sh`** (new, prefix `cit_`, sourced by the conductor):
   - The 8 knobs below, resolved through `lib_env_apply mc-ci-timeout`, with
     the code literal as the fallback when there is no registry. A non-integer
     value also falls back to the literal.
   - `cit_ledger_put` appends one ledger line under `flock`.
   - `cit_assess <slug> <key> <head> <base> <num> <flake-runs>` resets every
     `CIT_*` global, returns at once unless `MC_CI_TIMEOUT=1`, then runs
     `cit_scan`, stops if `CIT_TIMEOUTS` is empty, then `cit_rekick_step`, then
     `cit_budget_step`. A step that returns non-zero puts every global back to
     the reset values (fail open). It is called as a plain command, never in
     `$( )`, and always returns 0.
   - `cit_scan`, `cit_rekick_step` and `cit_budget_step` are one-line stubs
     that return 0 and change nothing.
2. **`bin/merge-conductor.sh`** sources the lib (optional, like
   `mc-stale-dequeue.sh`), resets `MC_CI_TIMEOUT_FIRING`/`_CHECK`/`_T`,
   `CIT_RUNS_LEFT` and `CIT_SKIP_RUNG` per PR, and calls `cit_assess` inside
   `if [ -n "$MC_FLAKE" ]`. The rung `case` now runs on `CIT_RUNS_LEFT` and is
   skipped when `CIT_SKIP_RUNG=1` or `CIT_RUNS_LEFT` is empty. `MC_FLAKE` itself
   is never changed, so `MC_CI_FLAKE`, the CI-kick skips and `mc_ci_word` read
   what they read before.
3. **`catalog/lanes.d/_lib.mc-ci-timeout.json`** registers the knobs as
   `lib.mc-ci-timeout.*` settings rows.

## Knobs

| env | default | range | what |
|---|---|---|---|
| `MC_CI_TIMEOUT` | 1 | 0..1 | 0 turns the feature off: the ladder runs on the full flake list |
| `MC_CI_TIMEOUT_SLACK_S` | 60 | 0..3600 s | how close to the limit a dead job must be to read as TIMEOUT |
| `MC_CI_TIMEOUT_DEFAULT_MIN` | 360 | 1..4320 min | the limit assumed when the workflow sets no `timeout-minutes` |
| `MC_CI_TIMEOUT_MIN_PRS` | 3 | 1..100 | distinct PRs that must show the same check timing out |
| `MC_CI_TIMEOUT_RATIO_PCT` | 50 | 1..100 % | share of the check's recent runs that must have timed out |
| `MC_CI_TIMEOUT_HISTORY_N` | 20 | 1..100 runs | recent runs read for the ratio and the percentiles |
| `MC_CI_TIMEOUT_HISTORY_MIN` | 10 | 1..100 runs | fewest runs before the budget may fire |
| `MC_CI_TIMEOUT_WINDOW_S` | 259200 | 3600..2592000 s | how far back the ledger is read |

In this slice only `MC_CI_TIMEOUT` is acted on.

## State files

Both sit in `$MC_STATE_DIR` (`state/merge-conductor/`), tab-separated.

- `ci-timeout.tsv`, one line per classified dead job, written by
  `cit_ledger_put` under `flock` on `ci-timeout.tsv.lock`. A tab or newline in
  the check name becomes a space, so a line always has 11 fields:
  `epoch slug check key head run_id duration_s timeout_min class wfpath run_started_at`.
  BH-3784 left `cit_ledger_put` uncalled; BH-3785's `cit_scan` writes one
  line per dead job on each flaked run.
- `ci-timeout-firing.tsv`, one line per budget firing:
  `epoch day slug check wfpath T X Y p50 p90 prs`. Nothing writes it yet.

`cit_scan` hands its result to the next steps as `CIT_TIMEOUTS`, one line per
TIMEOUT dead job: `run_id<TAB>check<TAB>wfpath<TAB>T<TAB>run_started_at`.

## Part files

The behaviour arrives as three optional files next to the lib. The lib sources
each one if it is readable, in this order, so its definition replaces the stub:

- `bin/lib/mc-ci-timeout-scan.sh` defines `cit_scan`.
- `bin/lib/mc-ci-timeout-rekick.sh` defines `cit_rekick_step` (may set
  `CIT_REKICK=1`, `CIT_SKIP_RUNG=1`).
- `bin/lib/mc-ci-timeout-budget.sh` defines `cit_budget_step` (may set
  `CIT_FIRING=1` and remove withheld lines from `CIT_RUNS_LEFT`).

## What usually lies

- Matrix and reusable-workflow job names never match a YAML `name:`, so their
  limit falls back to `MC_CI_TIMEOUT_DEFAULT_MIN` (360 min).
- A `cancel-in-progress` supersede that lands within the slack of the limit
  reads as TIMEOUT.
- The per-PR count undercounts on the first tick a repo is seen, because the
  ledger has no history for it yet.
- Two PRs on one head sha in one tick can write the same run twice: both miss
  the ledger and both write (BH-3785 takes no lock across the REST reads). A
  reader of the ledger counts distinct `(slug, run_id, check)`.
- A run with more than 100 jobs is classified on its first 100 (one jobs page).

## Verified by

`tests/mc/ci-timeout-contract.bh-3784-test.sh` (K1-K5b), and
`tests/ci-flake-classify.bh-636-test.sh` unchanged.
`tests/mc/ci-timeout-classify.bh-3775-test.sh` (C1-C8) pins the scan part file
`bin/lib/mc-ci-timeout-scan.sh` (BH-3785).
