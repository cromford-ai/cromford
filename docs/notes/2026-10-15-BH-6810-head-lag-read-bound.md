# The head-lag branch-tip read has a time bound (BH-6810)

Doc: MERGE-CONDUCTOR

## The gap

Sentry issue CROMFORD-HARNESS-R has 5 `conductor-step-timeout` events for step
`head-lag`, project project-9, harness sha `d1e0eaf7` (2026-10-14 14:25Z).
That sha is before BH-6670, so the kill paged.

BH-6670 held a read-only step timeout. It did not bound the call. In the
`head-lag` step, `head_lag_tip` reads the branch tip through `gh_rest`: the
refs read (`prs_branch_tip`) on a cache miss, then the live
`GET repos/<slug>/branches/<br>`. `gh_rest` ran `gh api` with no time bound,
and `gh` has no default HTTP timeout. A stalled connection held the step until
the watchdog killed the worker. The head-lag record read is already bounded
(`curl -m` in `bin/lib/jobs/req.sh`).

A normal head-lag run wrote no STEP_START/STEP_END line. The step runs before
READY, so it logged only when it took `MC_STEP_SLOW_S` or more.

## What changed

- `gh_rest` (`bin/lib/gh-rest.sh`) reads an opt-in `GH_REST_TIMEOUT_S`. When it
  is a positive integer, `timeout` is on PATH and `gh` is the binary (or the
  gh-limit-logger wrapper), the call runs as `timeout -k 5 <s> gh api ...`.
  A call cut with no status line is rc 75, `GH_REST_STATUS=000`,
  `GH_REST_REASON=timeout`. Unset, the call is the same as before. Only
  `head_lag_tip` sets the variable.
- `head_lag_tip` (`bin/lib/mc/rebase.sh`) sets it from
  `MC_HEAD_LAG_READ_TIMEOUT_S`, so both of its GitHub reads are bounded.
  Worst case for the step: 2 reads x (30 s + 5 s kill grace) = 70 s. That is
  under `MC_WORKER_DEADLINE_S` (180) and `MC_STEP_TIMEOUT_S` (240).
- `head_lag_check` writes one line per (PR, head) on a timed-out tip read:
  `<key> HEAD_LAG_HELD reason=tip-read-timeout: the tip read of <br> passed
  <s>s — head-lag not checked on <head8> this tick; the PR carries on, asked
  again every tick`. Attempts line: `headlag-held <key> <head>`. No
  STEP_TIMEOUT, no alert, no Sentry event. The PR carries on this tick, as for
  any unreadable tip. No head-lag clock starts and no kick is sent.
- `pr_worker` (`bin/merge-conductor.sh`) runs `mc_step head-lag` with
  `MC_STEP_LOG=1`, so every run writes `<key> STEP_START step=head-lag` and
  `<key> STEP_END step=head-lag took=<n>s`. The flag is restored after that
  call. The steps after it keep the old rule.
- Other reads (a 403/429 rate limit, a 404, a 500, a network error with no
  timeout) still write the old `head-lag check skipped` line.
- The BH-6670 hold stays the backstop for any stall the bound does not cover.

## Knobs

- `MC_HEAD_LAG_READ_TIMEOUT_S` (default 30 s, 0 = off, not a number = 30).
  Fragment: `catalog/lanes.d/merge-conductor.knobs.d/MC_HEAD_LAG_READ_TIMEOUT_S.json`.
  Settings row: `lane.merge-conductor.mc_head_lag_read_timeout_s`.
- `MC_STEP_LOG_HEAD_LAG` (default 1, 0 = the old rule, not 0 = 1).
  Fragment: `catalog/lanes.d/merge-conductor.knobs.d/MC_STEP_LOG_HEAD_LAG.json`.
  Settings row: `lane.merge-conductor.mc_step_log_head_lag`.

No new env var must be set.

## Probe after deploy

    grep -E 'HEAD_LAG_HELD|STEP_(START|END) step=head-lag' /root/harness/logs/merge-conductor.log | tail -5

Sentry issue CROMFORD-HARNESS-R must show 0 new events from a box at the merge sha.

Suite: `tests/mc-head-lag-bound.bh-6810-test.sh`.
