# BH-947: the rebuild rung holds on a live build and caps on the job ledger

Dated note, 2026-09-19. Slice 2 of 3 of #487. The contract it builds on
(`bin/lib/rebuild-ledger.sh`, `queue_row`) is #946, already on main.

## What changed

`bin/blocked-resolver.sh` only.

- NEW `br_queue_enq` — the `enqueued_at` stamp of the worker's row for a key;
  rc 1 when there is no reader, no row or no stamp.
- NEW `br_rebuild_inflight` — rc 0 (and the row printed) when a build of this
  ticket is `queued`/`claimed`; rc 1 when it is not live (done, failed, no row,
  or a box lane, which has no queue row by design); rc 2 when the queue could
  not be read — an outage is NEVER "finished"; rc 3 when there is nothing to
  ask (no key, or a jobs client without `queue_row`, so a box whose `bin/` has
  not synced never hangs).
- NEW `br_job_for_enq` — the ledger id for a row's `enqueued_at`. The ledger is
  matched on the stamp, not on the whole id: the id this lane mints carries a
  `~rN` suffix the worker's row has never seen.
- NEW `br_rebuild_wait` — THE HOLD. Sets `BR_REBUILD_WAITING=1`, writes
  `wait`/`wait_job` via `br_set_wait`, and logs `rebuild already in flight (job
  <id>, <status> on <machine>[, requested by <x>]) — waiting`. No event, no
  close, no counter bump.
- `br_enqueue_fresh` — clears `BR_JOB_ID`/`BR_JOB_ENQ` on entry; on `queued`
  reads the stamp back (`<KEY>@<stamp>~r<n+1>`, `~local` when the read-back
  failed) and answers rc 0; on `duplicate` logs `REFUSED as duplicate — a live
  build already covers this key (no rung spent)` and answers rc 3; anything
  else rc 1. rc 2 (no key) is unchanged.
- `br_rebuild_fresh` / `br_rebuild_retry` — how many builds this ticket has
  BOUGHT is the LARGER of `br_jobs_count` (the distinct job ids this lane
  enqueued) and the legacy `rebuilds` counter (review B1: a row parked before
  the ledger landed must not buy its ladder a second time). How LONG the ladder
  is stays BH-579's answer in `br_rebuild_fresh` — `br_rebuild_cap`, three for
  a large conflict and one for a small one; `br_rebuild_retry` keeps comparing
  against `MAX_REBUILDS`, as it did before this build. `br_rebuild_inflight` is
  asked BEFORE the cap check, the `br_event` and the `br_close_pr`, because
  every one of those assumes this rung is about to start something. At the cap
  with an unreadable queue the park HOLDS (`NOT abandoned`); at the cap
  otherwise the ABANDONED alert names every job id (`br_jobs_why`).
- `br_from_rebuilds` — clears `wait`/`wait_job` on the landed branch and beside
  every consumed failure: a build that ENDED clears the wait either way. A
  `done` row is never settled as failed from the queue probe — `PLAN_BLOCKED`
  and its siblings still route through `abandon-rebuild` and the 6h
  review-rescue floor.
- `br_one` — `BR_REBUILD_WAITING=0` beside `BR_HOLD_PARKED=0`, and after the
  action `case` a wait returns rc 3 BEFORE the hand-off release. A wait is not
  a rung: the conductor's park stays and the row costs no `PER_TICK` slot.

## Why

project-5 TK-1150, 2026-09-16: rung 3 enqueued one fresh build, the pool claimed
it, and the next two ticks read the worker's `duplicate` answer as rebuild 2 of
3 and 3 of 3. The ticket was ABANDONED with the one real build thirty minutes
into execute. On main `br_enqueue_fresh` maps `duplicate` to rc 0, the caller
bumps `rebuilds` on every rc 0, and the cap reads that counter — so one live
build burns the whole ladder in three ticks.

## The external job

A live row whose `enqueued_at` the ledger does not know was not enqueued by this
lane (a triage relaunch, a watchdog requeue). It is NOT added to the ledger —
the cap counts the rebuilds this lane bought — but on first sighting the rung
records exactly ONE `rebuild-fresh` attempt whose detail names it, so
`br_from_rebuilds` (which polls rows whose last non-hold attempt is
`rebuild-fresh`) consumes that build's RESULT when it ends. Jobs this lane did
enqueue already have their attempt and get nothing new. In `BR_OBSERVE=1` the
path logs `WOULD wait` and writes nothing.

## The rc 3 race, and what it costs

`br_rebuild_inflight` is a read, so a build can be claimed between that read and
the `queue_put` on the same tick. The worker answers `duplicate` and the rung
hands it to `br_enqueue_dup_race`, which re-probes and holds — but the
`resolver_rung` event and the stale PR's close have already gone out on that
tick. That is the documented cost: a PR closed once for a build that was already
running. The rung is still not counted and no attempt is appended for our own
job, so the ladder is not shortened by it.

The re-probe has to actually land, and in round 1 of review it did not: the arm
re-used the caller's `inflight_rc`, and `|| inflight_rc=$?` assigns only on
failure, so a successful re-probe was read as a failed one, `wait_job` was always
the placeholder `<KEY>@duplicate-race`, and the racing external job got no
`rebuild-fresh` attempt. That is the double-build this ticket exists to stop,
one tick later: the racing build finishes with `PR_CREATED`, nothing consumes
its RESULT, the next tick reads `done` with the cap unspent and enqueues on top
of it. `br_enqueue_dup_race` now owns a local `inflight_rc=0`, and
`tests/blocked-resolver.bh-947-test.sh` case 11 drives the race end to end.

## Out of scope

The original #487 question — whether a head that was never re-approved should
reach this rung at all — stays open. This slice changes only what the rung does
once it has been chosen; the ladder that chooses it (`br_ladder_rung`,
`br_action`) is untouched.

## Verification

- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-947-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/rebuild-ledger.bh-946-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-614-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/pr-create-failed-owned.bh-614-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1122-test.sh` — the
  enqueue-failure episode streak, which the landed path's `enqueue_why` clear
  belongs to.

## Proof after merge

`logs/blocked-resolver.log` on the hub: the next real `head-not-reapproved`
rebuild on any project shows `rebuild already in flight (job <KEY>@<stamp>` on
the ticks after the first, and no `rebuild 2 of 3` within twenty minutes.

## Files

- `bin/blocked-resolver.sh`
- `tests/blocked-resolver.bh-947-test.sh`
- `docs/verification-map/rebuild-wait.md`
- `docs/verification-map/entries/BH-947.md`
