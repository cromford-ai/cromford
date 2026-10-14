# The conductor's CI writes check the PR's live head first (BH-3804)

Doc: MERGE-CONDUCTOR, FLAKY-TESTS

## What changed

Every CI write the merge conductor makes now re-reads the PR's head right
before it writes. That covers the red-ladder rerun (`mc_red_rerun`), the
known-flake rerun (`mc_flake_rerun`), the killed-runner rerun
(`mc_flake_kick`) and the close/reopen kick (`mc_kick_ci`, when the caller
passes the head it expects).

- One `gh_rest GET repos/<slug>/pulls/<n>` read, in `mc_head_still`
  (`bin/lib/mc/classify.sh`). Not memoised.
- Head moved: nothing is dispatched and no `cirerun` / `flakererun` mark is
  written for either sha. The log says
  `<key> stale head: tick read <old>, PR is at <new> — no rerun` (or `no CI
  kick`) and the per-tick counter `stale_head_rerun_skipped` goes up. The
  next tick starts the new head's ladder at rung 0.
- Head unreadable: nothing is dispatched and no rung is spent. The next tick
  asks again.
- `flaky_failed_runs` (`bin/lib/flaky.sh`) prints a fourth field, the run's
  `head_sha`, and `mc_ci_flake_runs` a third. A listed run whose sha is not the
  live head is skipped and named in the log. An empty field falls back to the
  list's own `head_sha=` filter.
- `stale_head_rerun_skipped=<n>` ends the `TICK` line and is in
  `state/merge-conductor/tick-<project>.json`.

`head_lag_kick` still calls `mc_kick_ci` with no head. Its whole premise is
that the PR's `head.sha` lags the branch, so a stale answer there is the
expected state, and refusing would spend its refusal budget for nothing.

## Why

project-4 #1815, 2026-10-01. The tick read head `3b0fd01b`, a fix was pushed
(`94fafc78`), and the red ladder re-ran the old head's failed run. The repo's
`unit-tests.yml` has a per-PR `concurrency` group with `cancel-in-progress`, so
that rerun cancelled every shard of the current head's run.

## How to see it

`grep 'stale head: tick read' logs/merge-conductor.log` and
`grep -o 'stale_head_rerun_skipped=[0-9]*' logs/merge-conductor.log | sort | uniq -c`.
Suite: `tests/mc/rerun-stale-head.bh-3804-test.sh`.
