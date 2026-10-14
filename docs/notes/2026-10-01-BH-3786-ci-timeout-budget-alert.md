# The CI timeout budget fires: one repo page, no doomed rerun (BH-3786)

Doc: MERGE-CONDUCTOR

This is the budget slice of BH-3775. It corrects the status line of
[2026-10-01-BH-3775-ci-timeout-budget.md](2026-10-01-BH-3775-ci-timeout-budget.md):
`cit_budget_step`, `CI_TIMEOUT_BUDGET`, `CI_TIMEOUT_NO_RERUN` and
`ci-timeout-firing.tsv` are live once this merges. The scan (BH-3785) is still
the only writer of the ledger, so in production nothing fires until it lands.

## What changed

1. **`bin/lib/mc-ci-timeout-budget.sh`** (new part file, sourced by
   `bin/lib/mc-ci-timeout.sh`, replaces the `cit_budget_step` stub):
   - `cit_firing` decides per (repo, check). PR arm: TIMEOUT ledger lines inside
     `MC_CI_TIMEOUT_WINDOW_S` from at least `MC_CI_TIMEOUT_MIN_PRS` distinct
     PRs that are still open (this PR counts; a `MERGED`/`CLOSED*` row or a key
     with no row does not). Ratio arm, only when the PR arm did not fire: of the
     workflow's last `MC_CI_TIMEOUT_HISTORY_N` completed runs (at least
     `_HISTORY_MIN`), at least `MC_CI_TIMEOUT_RATIO_PCT` % were
     cancelled/timed_out at or past `T*60 - MC_CI_TIMEOUT_SLACK_S` seconds.
     The history is read once per (repo, workflow, tick) through `gh_rest`,
     under a flock'd tick file; a failed read is cached as `ERR` and the arm
     does not fire.
   - `cit_alert_once` pages `CI_TIMEOUT_BUDGET` once per (repo, check, UTC
     day): the marker `citimeout <slug> <cksum(check)> <YYYYMMDD>` in
     `attempts.txt`, checked and appended under `attempts.txt.lock` like
     BH-800's `identityalert`. The owner of the marker appends one line to
     `ci-timeout-firing.tsv`. It pages in observe mode too.
   - `cit_budget_step` takes out of `CIT_RUNS_LEFT` every run whose dead jobs
     are all TIMEOUT on a firing check (one FLAKE job, or a TIMEOUT on a check
     that is not firing, keeps the run). When it withheld anything it logs
     `CI_TIMEOUT_NO_RERUN` once per (PR, head) with a `citskip` mark in actions
     mode, and every tick with no mark in observe mode. "Actions mode" is the
     conductor's own `ACTIONS` (the actions flag, minus observe and kill).
2. **`bin/lib/mc/classify.sh`**: while `MC_CI_TIMEOUT_FIRING=1` the flake reason
   becomes `checks timeout budget — "<check>" dies at its <T>-min limit
   (CI_TIMEOUT_BUDGET; no rerun)`, on both the `ci=none` and the
   BLOCKED/UNSTABLE arm. With it 0 every reason is byte-identical.

## Verified by

`tests/mc/ci-timeout-budget-alert.bh-3775-test.sh` (D1-D5, E1-E6, through the
real conductor; `CIT_NO_BUDGET=1` runs it without the part file, the red-first
check).
