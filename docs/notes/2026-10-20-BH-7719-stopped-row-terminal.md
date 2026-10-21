# A stopped pool machine's pool-result row is its result, not a requeue (BH-7719)

Doc: FLY-POOL

## Problem

On 2026-10-20 the Fly pool started 193 machines that finished their job,
idled 600 s and stopped before the hub reaped them. Each one wrote a
pool-result row. The REAP loop in `bin/fly-pool.sh` took that row as the
result only for `BUILD_DEFERRED`, `ROLLOUT_FILED` and `ROLLOUT_FAILED`. Every
other row went to the dead path, which requeued the job "not a death". The
next machine planned again and got the same answer: 98 pure repeats. No Fly
cost row was written for any of them. Each re-plan of a PLAN_BLOCKED ticket
worded the question differently, so `pb_notice` posted again: 11 comments on
#7655.

## What changed

1. The row arm. For a non-`RB-`, non-`RR-` key on a machine that is not
   started, every row that `pool_result_row_get` accepts (rc 0) is the
   result. It goes down the same path as an ssh-read result: the deferral
   arm, the PR verify gate, `QROW done`, `state/remote-results`, the ledger
   check and the relay. No row, a stale row, a row of another machine and an
   unreadable ledger are still deaths. The dead path no longer has a
   "stopped after job done" branch.
2. The hold. A row-sourced PLAN_BLOCKED logs `held <KEY>: PLAN_BLOCKED from
   the pool-result row — not requeued`. The hold itself is the queue row
   closed `done` with its `PLAN_BLOCKED` reason, which `pb_stranded_skip`
   (`bin/orphan-reconcile.sh --stranded`) already honors until a person
   answers.
3. The Fly cost row. The row arm and the dead path now call
   `pool_fly_cost_row`. The dead path uses a temp dir as the build dir.
   `pool_fly_cost_row` ends the interval at the listing's `updated_at` when
   the machine is `stopped`, `suspended`, `failed` or `destroyed`, and that
   time is after `spawned_at` and not in the future. Otherwise the end is the
   tick, as before. `state/fly-cost/ledger.tsv` still keeps one row per
   (machine, key, spawned_at).
4. One notice per ticket. `pb_notice` keeps its per-reason token. After a
   2xx POST it also writes the per-ticket marker: `ledgers` kind
   `commented`, key `plan-blocked-last <project> <KEY>`, detail the epoch of
   the post, plus the file `state/plan-blocked/<project>/<KEY>.last`. When
   the marker exists, the next notice reads the issue comments `since` that
   epoch and posts only if a human comment (not a Bot, not our App) was
   created or edited after it. A thread that cannot be read holds the
   notice (BH-2317: a double comment is the worse failure). A held notice
   marks RESULT line 1 with the builder-direct note, so the owning box's
   sweep does not post either. `cm_clear "plan-blocked-last <p> <KEY>"`
   lifts the marker.

## Not changed

- `POOL_RECORD_READ` keeps its default (0). The terminal result no longer
  depends on it: the pool-result row is written for every non-`RR-` key.
- The runner's 600 s idle timeout (`IDLE_TIMEOUT_DEFAULT`).
- The orphan sweep (a machine with no machine json) writes no cost row: it
  has no key to bill.
