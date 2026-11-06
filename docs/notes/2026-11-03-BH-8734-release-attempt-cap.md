# BH-8734 slice C0: the release counter and the re-review apply-failed stop

## The case

BH-8841 ran 17 times for $15.73. Each run ended in `GATE_RED`, a build word
since a4a07a3b3 (BH-8062). The pool reap matched that word against the rebase
arm. `mc_pool_rebase_apply` found no RB job file and answered rc 1. The pool
logged `apply refused — row left claimed`. About 30 s later the orphan release
put the row back to `queued`, and the pool spawned it again.
`build_queue.attempt` stayed at 2 through all 17 runs, because no release
touched it. Only the EXECUTE_EMPTY cap stopped the loop.

## What main already had (BH-8886, 807f2e401)

- The pool rebase reap arm runs only for an `RB-` key. A build key's
  `GATE_RED` goes to the build reap.
- A refused rebase apply closes its row `failed` (`APPLY_FAILED rc=<n>`) with
  one ALERTS line.

This slice does not change either. `tests/pool-gate-red-build-key.bh-8886-test.sh`
pins them.

## What changed

- `config/fly-pool.d/3400-pool-listing-and-reap.sh` (rendered into
  `bin/fly-pool.sh`): a refused re-review apply ends the row `failed` (reason
  `re-review apply failed rc=<rc>; RESULT at <path>`), with one ALERTS line
  that says FAILED. Before, the row stayed claimed, and the jobs-watchdog
  stale-claim release (no key filter) put it back to `queued` after 360 min.
- `PATCH /api/queue` takes `count_attempt: true` (a boolean, with
  `status: "queued"`). On a `claimed` row the worker adds 1 to `attempt`. If
  the new value is more than settings row `queue.release_attempt_max`
  (seed 3, code fallback 3), the row is written `failed` with reason
  `release cap: attempt <a> of <N> (queue.release_attempt_max); <reason>`.
  The UPDATE is a compare-and-set on `status='claimed'`. A counted release of
  a row that is not `claimed` answers 409 `{error:"stale", current}` and
  writes nothing, because `failed -> queued` is a legal transition.
- `queue_release_counted` (bin/lib/jobs/queue.sh) sends it and prints
  `queued <a>`, `failed <a> <max>` or `stale <current>`.
- `pool_orphan_rows_step` and the jobs-watchdog stale-claim release use it.
  A capped row gets one say line, and one ALERTS line per pool tick names
  every capped key (`QUEUE CLAIM RELEASE CAP` per row in the watchdog). A box
  without `queue_release_counted` uses today's `queue_release`.
- The pool, dispatch and docker-pool un-claims still call `queue_release`.
  No work ran there, so they do not count.

## The reason-word rule

No new reason contains `refused` or `BUILD_DEFERRED`. The watchdog's
`reason_deferred` read matches `reason LIKE '%REFUSED%'`, case-insensitive in
SQLite, and would put the row back on the queue.

## Left on this ticket

- C1: `POST /api/queue` refuses `plan_blocked`/`abandoned` unless the actor is
  `lifecycle`, and the jobs-watchdog holds an RR/LR row closed
  `AGENT_CALL_REFUSED call-guard repeat`.
- C2: `bin/orphan-reconcile.sh` drops the thread scan. Blocked by #8733.
