# BH-9457: the reconcile decides a relaunch from the DB phase

Date: 2026-11-11. Issue #9457, the last item of #9160 (body item 2 of #8734).

Doc: EVENTS

## What changed

- `bin/orphan-reconcile.sh`, both modes (the triage tick and `--stranded`), calls
  the pool's own spawn gate `pbs_stop_check` (bin/lib/plan-blocked-stop.sh) at
  the place where the thread scan was. That is after awaiting-closeout and before
  the cap, so a skip takes no slot.
- Phase plan_blocked, abandoned, ejected or in_queue: the key is skipped as
  `<KEY>:phase-<phase>`. There is no launch, no queue row, no `.enqueued` marker,
  no re-offer count, no "reconciliation enqueued" alert and no NEEDS_HUMAN. The
  log line quotes the gate:
  `reconcile: TK-201 (issue #201) skip :: skipping TK-201: phase plan_blocked since <phase_at> ...`
  (the prefix is `stranded:` in the stranded watch).
- Any other phase, NULL, or no row: the key launches as before. An unreadable
  phase (queue outage) launches too, with one line
  `reconcile: <KEY> (issue #N) <KEY>: phase unreadable — not gated this tick`.
- `stranded_reoffer` reads `queue_put` rc 3 (the worker's 409 `phase_refused`,
  BH-9160) as the same skip: `stranded: <KEY> (issue #N) skip :: ticket phase
  <phase>; only the lifecycle actor re-enters it`. Before this change the lane
  logged it as `queue-unreachable`.

## What was removed

- The thread scan `pb_stranded_skip` (bin/lib/plan-blocked.sh). It decided from
  the queue reason word `PLAN_BLOCKED` and from a walk of the issue thread for a
  human comment newer than the row. The thread and the queue reason now decide
  nothing. `_pb_answers_since` stays: `pb_notice` and bin/lib/defer-after-stop.sh
  use it.
- The knob `STRANDED_SKIP_PLAN_BLOCKED` and its row
  `catalog/lanes.d/stranded-watch.knobs.d/STRANDED_SKIP_PLAN_BLOCKED.json`. No
  knob replaces it: a switch to turn off the one decider would bring back two
  deciders. A settings row `lane.stranded-watch.STRANDED_SKIP_PLAN_BLOCKED` that
  is still in the DB is read by nothing. It can be deleted at any time.
- The skip token `<KEY>:plan-blocked`. No code parses it. Look for
  `:phase-plan_blocked` in `reconcile: open=` and `stranded-watch: open=` lines.

## Why it is safe now

BH-9160 deferred this item because no code wrote `phase=plan_blocked`. Commit
095673749 (BH-8733) made the pool reap write `plan_blocked` and the question
(bin/lib/pool-lifecycle.sh `pool_phase_reap`). So the pool and the reconcile now
use one rule that reads one column.

## Limits

- Local builder. Only the pool reap writes `plan_blocked`. A project whose
  builder is `local` (not the pool) gets no phase, so the reconcile relaunches
  its PLAN_BLOCKED tickets. The plan assumes the issue-board projects that run
  this lane build through the pool.
- The gate's knob `POOL_PLAN_BLOCKED_STOP` is a fly-pool lane row. The reconcile
  does not apply that lane's env, so it reads the default 1.

## Tests

- tests/orphan-reconcile-phase-gate.bh-9457-test.sh (new, G1-G9).
- tests/orphan-reconcile-plan-blocked.bh-7116-test.sh and
  tests/orphan-reconcile-triage-plan-blocked.bh-8707-test.sh: the thread-scan
  and knob cases now pin the phase rule.
