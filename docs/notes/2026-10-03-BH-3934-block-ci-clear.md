# A BLOCK that only says "CI did not run" clears itself when CI is green (BH-3934)

Doc: MERGE-CONDUCTOR, block-gate

## What changed

- `bin/lib/mc/block-ci.sh`: `mc_block_ci_step` replaces the BH-3932 stub. The
  conductor's READY arm calls it after a block-gate refusal with the block id
  (`bin/merge-conductor.sh`, unchanged; its rc is ignored and the refusal stands
  that tick). It:
  - declines (rc 2) a bad argument, a `cr-*` id (a standing
    CHANGES_REQUESTED), a missing helper, or a body it cannot read. The body is
    read by id: a PR review on this PR first, then an issue comment on this
    repo; for `verdict-<id>` the verdicts row's report URL.
  - declines a body that `ph_ci_only_body` rejects, and also one that carries a
    success/contrast word (`passed`, `green`, `but`, `however`, …) or a non-CI
    subject (`migration`, `deploy`, `prod`, `cron`, `db`, …). That closes the
    false positive `bin/lib/pr-health.sh` records ("CI passed, but the
    migration did not run on prod").
  - dispatches CI once per (PR, head): the `pr_attempts` row `blockci` is
    written before any POST, so a failed POST is never retried. A cancelled or
    skipped latest run is re-run; otherwise it dispatches the workflow the body
    names, else `harness-ci.yml`, else the first active workflow whose file has
    a `workflow_dispatch` trigger (at most 20 file reads). A failed POST logs
    `BLOCK_CI_DISPATCH_FAILED` and sends one `mc_alert`; a 422 is logged only.
    Reads that fail before the row is written leave no row, so the next tick
    tries again.
  - clears only when every job of every latest-per-workflow run whose
    `head_sha` is exactly the head concluded `success` (`skipped` is not, zero
    jobs is not, a jobs page short of `total_count` is not). It then writes
    `ledgers` `block_ci_clear` / `<slug>#<num>@<head>` / `cleared` /
    `"<run-id> <id> [<id>…]"` (ids accumulate, so a second block's clear keeps
    the first) and logs `block-cleared-by-ci <pr> <sha> <run>` after the put.
  - in observe mode (`ACTIONS != 1`) logs `WOULD dispatch` / `WOULD clear` and
    writes nothing.
- `bin/lib/block-gate.sh`: `bg_ci_cleared_ids` reads that row; `bg_scan_read`
  consults it at the `verdict-*` early return and at the end of the pending
  walk, and drops only a block whose id is a whole word of the row's ids. No
  row, a non-`cleared` status, a short head, or a ledger outage lifts nothing.
  The CR-standing return is not consulted.

## Why

project-4 #1795 sat three days on a BLOCK whose only finding was that CI had not
run, and BH #3879 was refused every tick for the same reason. Nobody re-ran CI
or posted a clear.

## Pinned by

`tests/block-gate-ci-clear.bh-3929-test.sh`
