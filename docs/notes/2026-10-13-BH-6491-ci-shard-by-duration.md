# CI plan: shard count by recorded suite duration (BH-6491)

Doc: ci-cost-lanes, VERIFICATION-MAP

## What happened

`bin/ci-plan.sh` set the shard count as `ceil(suites / CI_SUITES_PER_SHARD)`.
On 2026-10-13 batch #6418 ran 93 suites on 1 shard and took 32 min. Five slow
suites set the wall time. The split INTO shards was already balanced by
duration (`suite_shard_plan`). Only the count ignored durations.

## What changed

The first build of this ticket (2026-10-13/14) added its own sizing rule
(`suite_shard_count`, `CI_PLAN_DURATIONS`, a D1 row `ci_plan.shard_target_s`).
It never got a PR. On 2026-10-16 BH-6876 (PR #6997) merged the same feature on
main: `CI_PLAN_DURATIONS_FILE`, `suite_shard_size`, and the knobs
`CI_SHARD_BUDGET_S` (default 480 s) and `CI_MAX_SHARDS` (default 8) in
`catalog/lanes.d/ci-plan-settings.knobs.d/`. The rebase on 2026-10-21 drops the
duplicate rule and keeps main's. What BH-6491 still adds:

- `tests/ci-plan-shard-by-duration.bh-6491-test.sh`: acceptance 1 on main's
  rule. 93 suites, 5 at 6 min, give at least 3 shards and none over 12 min. A
  missing or sourceless file keeps the count rule and logs
  `ci-plan: sizing: count, ... (<why>)`.
- `bin/ci-plan.sh`: a batch's plan job also sends the sizing line as
  `::notice title=ci-plan sizing::`. It has its own title, so the readers of
  `title == "ci-plan"` do not see it.
- `bin/ci-shard-replay.sh`: per selected-mode merge-queue batch, the actual
  max shard wall, the runner minutes, and the max that `suite_shard_size`
  predicts from that run's own `ci-durations` artifact (budget and cap from
  the run's sizing notice). It counts the no-ledger runs.

## Replay (2026-10-14, before BH-6876)

`bin/ci-shard-replay.sh --last 30` read 30 runs. 22 were selected-mode batches.
The actual max shard mean was 27.3 min. The predicted max mean was 14.9 min
(600 s target, cap 8). 17 of the 22 stopped at the 8-shard cap. The no-ledger
fallback fired 0 times in 22. the operator accepted 14.9 min on 2026-10-14.

## Commands

- `bin/ci-shard-replay.sh --last 30` (artifacts expire after 3 days).
- `bin/ci-shard-replay.sh --since <merge time>`: the acceptance-3 re-measure.
