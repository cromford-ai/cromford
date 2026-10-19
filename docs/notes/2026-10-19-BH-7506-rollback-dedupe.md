# Deploy train: one rollback PR per failed target (BH-7506)

Doc: OPERATING

## What changed

`bin/deploy-train.sh` runs a gate before it cuts a rollback branch. The gate is
`drg_gate` in `bin/lib/deploy-rollback-guard.sh`. It runs once per failed verify
when `DEPLOY_ROLLBACK=on`. It gives one verdict:

| verdict | when | PR | beat | ledger row | log line |
|---|---|---|---|---|---|
| open | none of the rows below | 1 (the old path) | the old rollback beat | `opened` | `rollback PR … enqueued` |
| dup | a ledger row for this target in any status, or an open harness rollback PR that names the target or reverts the same shas | 0 | 0 | unchanged | `rollback skipped (dup): …` |
| stale | the newest batch commit is older than `max_age_min` | 0 | 1, akey `rollback-stale:<p>:<t8>` | `stale` | `rollback skipped (stale): batch age Xm > Ym` |
| cap | open harness rollback PRs >= `max_open` | 0 | 1 critical, akey `rollback-cap:<p>:<t8>` | `capped` | `rollback skipped (cap): N open >= max M` |
| unknown | the open-PR list did not answer, a batch commit time is unreadable, or the lib did not load | 0 | 1, akey `rollback-unknown:<p>:<t8>` | none | `rollback skipped (unknown): …` |

The `capped` and `stale` rows make the next run on the same target a `dup`. So
one failed target gets one beat, not one beat per hour. A `dup` with a known PR
url calls `bin/deploy-rollback-board.sh` again, so a board comment that was
refused is still retried (BH-4915).

A harness rollback PR has a `rollback/` head AND the body text
`Automatic rollback (deploy train`. A new rollback PR body also has the line
`Rollback-Target: <40-hex sha>`. An older body without that line matches on
`failed to serve <first 8 of the sha>`.

Before it decides, the gate sweeps. It closes each open harness rollback PR
older than `max_age_min`, with one comment. It removes the PR's
`state/merge-queue/<project>/<n>` marker and sets the PR's target row to
`closed`. It closes at most 20 PRs per run, and the log line names how many
are left. `bin/merge-conductor.sh` does not change.

## Knobs

| settings row | env fallback | default |
|---|---|---|
| `deploy_train.rollback_max_open.<project>` | `DEPLOY_ROLLBACK_MAX_OPEN` | 1 |
| `deploy_train.rollback_max_age_min` | `DEPLOY_ROLLBACK_MAX_AGE_MIN` | 120 |

No seed row is written. A value that is not a whole number uses the default and
writes one log line (`rollback guard: bad value …`).

## The dedupe row

Kind `deploy_train_rollback` in the D1 `ledgers` table. Key
`<project>@<40-hex target sha>`. Status `opened`, `capped`, `stale` or `closed`.
Detail JSON: `pr`, `url`, `reverted` (the batch shas) and one time key
(`opened_at`, `capped_at`, `stale_at` or `closed_at`).

The ledgers PRIMARY KEY (kind, key) serves the one read. The ledgers retention
rule applies: the rows are history and are not deleted. To archive old rows,
add `deploy_train_rollback` to the settings row
`retention.ledgers.archive_kinds` (BH-6780). An archived row is still readable,
so it still dedupes. Volume is at most one row per failed target.

## Check it

- `logs/deploy-train.log`: `rollback skipped (…)` and `rollback swept PR #N` lines.
- `GET /api/ledger?kind=deploy_train_rollback&key=<project>@<sha>`.
- Test: `tests/deploy-train-rollback-dedupe.bh-7506-test.sh`.
