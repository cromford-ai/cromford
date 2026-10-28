# BH-8707: the triage-tick reconcile skips unanswered PLAN_BLOCKED tickets

Ticket: BH-8707. Related: #8309 (PR #8340, the pool-side gate).

## What changed

- `bin/orphan-reconcile.sh` runs the BH-7116 guard `pb_stranded_skip` in both
  modes: the triage tick (no flag) and the stranded watch (`--stranded`).
  Before, only the stranded watch ran it.
- A ticket whose last queue row ended `PLAN_BLOCKED`, with no human comment
  created or edited since, is skipped as `<KEY>:plan-blocked`. The triage tick
  logs `reconcile: <KEY> (issue #N) skip :: last build ended PLAN_BLOCKED at
  <iso> and no human comment since`. The stranded watch keeps its `stranded:`
  line.
- The knob is the same row for both modes: `STRANDED_SKIP_PLAN_BLOCKED` on the
  stranded-watch lane (default 1; 0 relaunches as before). The triage tick
  reads it in a subshell, so no other stranded-watch knob reaches the tick.
- A skip is not an enqueue. The "reconciliation enqueued" alert fires only when
  the run launched a build, and its "Each had ..." list names only the launched
  keys. A skipped key shows only in its "Held back this run:" tail.

## Why

On 2026-10-27/28 the stranded watch skipped BH-8467, but the box-small
triage tick relaunched it 5 times in one night. Each build blocked again, and
each relaunch fired a critical alert. BH-8467, BH-8634, BH-8646 and BH-8666 hit
the pool spawn cap (12 of 12 in 24 h).

## Owed after deploy

Fleet proof: one day after the deploy, 0 cromford keys with more than 2
PLAN_BLOCKED reaps in 24 h in `logs/fly-pool.log`. A build box cannot measure
this.

## Tests

`tests/orphan-reconcile-triage-plan-blocked.bh-8707-test.sh` (P1-P7, K1-K2,
A1-A2). `tests/orphan-reconcile-plan-blocked.bh-7116-test.sh` R5 now asserts the
triage-tick skip.
