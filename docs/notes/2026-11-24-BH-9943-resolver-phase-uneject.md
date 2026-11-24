# BH-9943: a resolver re-plan moves an `ejected` ticket to `pr_open`

Doc: MERGE-CONDUCTOR

## Cause

On bh-hub-2, 2026-11-23, `logs/blocked-resolver.log` said `stale park
RE-PLANNED — BH-9453 enqueued fresh`, and every pool pass then said `skipping
BH-9453: phase ejected since 2026-11-12T18:58:23Z — not spawned`. The same was
true of BH-9465, BH-9693 and BH-9075. The 4 queue rows waited 6 to 12 days. A
person moved them by hand on 2026-11-24 00:19Z (events 1848 to 1851).

The stale-replan rung and the rebuild-fresh rung enqueue through
`br_enqueue_fresh`. That function did not move the lifecycle phase, and
nothing else moves a phase out of `ejected`. `pbs_stop_check`
(`bin/lib/plan-blocked-stop.sh`) refuses a spawn in phase `ejected`.

## Change

- `bin/blocked-resolver.d/bh-9943-phase-uneject.sh` (new): `br_phase_uneject <project> <key> <reason>`.
  It reads the phase once (`pool_phase_get`). Only on phase `ejected` it sends
  one `lifecycle_transition ... pr_open lifecycle "blocked-resolver: <reason>"`.
  A 409 whose `current` is `pr_open` is success (the move already landed). Any
  other refusal, a 404 or an outage is rc 1 with `PU_WHY`. An unreadable phase
  is rc 0 with one line, the same fail-open as the spawn gate.
- `br_enqueue_fresh` (`bin/blocked-resolver.sh`) calls it after a pool `queued`
  or `duplicate` answer. A failed move is rc 1 with `BR_ENQUEUE_WHY` set. All 4
  callers (stale-replan, rebuild-fresh, rebuild-retry, CI re-plan) already read
  rc 1 as "not this tick, nothing spent", and their own line names the error
  once. The next tick gets `duplicate` from the queue and moves the phase then.
  If the fragment is not loaded (missing, or BR_OPT_OFF=bh-9943-phase-uneject),
  the call site is skipped and the rung keeps its rc, as before BH-9943.
- `sqg_gate` (`bin/lib/stuckqueue-gate.sh`): a pool line with `phase ejected`
  is the gate `phase-ejected`. The detail starts `phase ejected, re-planned:`
  when the `logs/blocked-resolver.log` tail names the key (whole word) with
  `RE-PLANNED` or `fresh pool build enqueued`, else `phase ejected:`.

## The actor

`lifecycle`. `worker/jobs/src/lib/lifecycle.js` gives a move out of
`plan_blocked`, `abandoned` or `ejected` (not to abandoned or closed) to the
`lifecycle` actor only (the re-entry rule of BH-8731 and BH-8736).
`ejected -> pr_open` is a legal move. The hand fix used the same actor. A
`resolver` actor gets 409 `wrong_owner`. The worker rules do not change, and
the lib acts only on phase `ejected`, so who may leave `plan_blocked` or
`abandoned` does not widen.

## Test

- `tests/blocked-resolver-uneject.bh-9943-test.sh`: U (the decision table), S
  (the real stale rung against a stub jobs worker that judges each move with
  `lifecycleCheck` from the worker), R (the rebuild-fresh rung), G (the gate
  class and the real pipeline-health stuck-queue block). On the old code, S1
  fails: the re-plan is counted, the phase stays `ejected` and
  `pbs_stop_check` refuses the key.
- `worker/jobs/test/lifecycle-uneject.bh-9943.test.js`: `ejected -> pr_open`
  by `lifecycle` is 200; by `resolver` or `pool` it is `wrong_owner`;
  `plan_blocked -> pr_open` and `abandoned -> pr_open` stay `illegal_transition`.

## After deploy

After the next re-plan of an ejected ticket, `logs/blocked-resolver.log` has
`<KEY>: phase ejected -> pr_open (actor lifecycle, ...)`, and
`bin/jobs-client.sh lifecycle-history <project> <KEY>` shows the event.
