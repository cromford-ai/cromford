# The default queue's batch size is 3 (BH-8267)

Doc: MERGE-CONDUCTOR, MERGIFY

## What changed

- The cromford `default` queue runs `batch_size: 3`, `batch_max_wait_time: 2 min`, and 1 batch in flight (`max_parallel_checks: 1`).
- The value lives in `config/mergify/repos/cromford.conf` (`batch_size=`). Edit `.mergify.yml` to match in the same PR. `bin/mergify-template.sh --check` renders the conf and compares the two.
- The `hotfix`, `flake-fix` and `solo` queues stay at 1.

## Why

the operator set it on 2026-10-24 as a CI cost hotfix. Batches were 11,002 of 13,492 raw MonkCI minutes on 2026-10-24. About half of the batches of 2026-10-23 were red. A red batch spends its whole test selection, so at a 50 percent red rate a batch of 3 wastes less than a batch of 6.

## When it goes back to 6

The value goes back to 6 when the rate line of `bin/ci-batch-red-report.sh --days 7 --dry-run` shows under 15 percent for 7 days in a row. The rate line is `ci-batch-red: red-batch rate, last 7 days: <pct> percent ...`. Read it with `grep 'red-batch rate'`: in `--dry-run` a failed record write logs to stdout before it.

Tests: `tests/ci-batch-red-report.bh-8267-test.sh`, `tests/mergify-template.bh-1673-test.sh`, `tests/mergify-template.bh-8047-test.sh`.
