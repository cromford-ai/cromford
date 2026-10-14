# Overlap deferrals stop using up the per-key pool spawn cap (BH-5912)

Doc: FLY-POOL-RESPAWN-CAP

## What was wrong

The pool records one `.spawns` line for each machine it spawns. The cap is 12
per key in 24 h on project-6-os. The reap took a line back off only for a
refused claim (BH-1279), a dirty slot (BH-5021) and a lane failure. A machine
that stood down on an overlap with a sibling kept its line.

- TK-7 (2026-10-09 22:53Z) used all 12 spawns. Each machine ended
  `OVERLAP_DEFER` behind TK-6, TK-8 or TK-9. No build ran. An operator moved
  `state/pool/project-6-os/TK-7.spawns` aside to free it.
- TK-17 (2026-10-10) reached 11 of 12 the same way, behind TK-19 and TK-18.

Each such machine costs a boot plus a plan or overlap check (about
$0.05-0.10).

## What changed

1. **The reap un-records an overlap deferral.** `pool_overlap_deferral` in
   `bin/fly-pool.sh` matches four RESULT prefixes that `bin/lib/rb/gates.sh`
   writes: `BUILD_DEFERRED OVERLAP_DEFER`, `BUILD_DEFERRED After: `,
   `BUILD_DEFERRED plan overlap not-before ` and `BUILD_DEFERRED file overlap `.
   For these, the reap calls `pool_spawn_cap_unrecord`, the same call a refused
   claim gets. Every other deferral still counts.
2. **No machine while an `After:` hold is live.** `pool_spawn_decision` has a
   step 3b, after the terminal check and before the cap. For a row with
   `deferrals` > 0 it runs `bin/plan-after.sh check <project> <KEY>`. On rc 3
   with output it logs
   `skipping <KEY>: After: <OTHER> <why> — no machine spawned; re-checked next tick`
   and keeps the row queued. The spawn loop and the reuse handoff in
   `next_job_or_destroy` both run this step. On the hub, plan-after.sh has no
   local marker, so it reads the key's `overlap_defer` fleet row, then the
   sibling's claims, build dirs, `job_claims` row and open PR.
3. **The resolver owns legacy cap parks.** `br_from_queue` in
   `bin/blocked-resolver.sh` offers a FAILED row whose reason is
   `pool spawn cap … deferred to a human` as `pool-deferred-max`. `br_action`
   maps that to `rebuild-fresh`, the capped 3-try rebuild ladder.

## Why the loop stays bounded

The cap no longer bounds overlap deferrals. `deferrals` still advances on each
one, so `DEFER_MAX` (default 6) parks the row `deferred N times`. The resolver
then rebuilds it at most 3 times and records ABANDONED after that.

## Rows parked before BH-4859

The BH-4859 note says an operator recovers `failed … deferred to a human` rows
by hand. That is no longer necessary: the resolver picks them up as candidates.
The cap is a timed retry since BH-4859, so a rebuild re-enqueue waits for the
window and does not re-park.

## Out of scope

`stack-wait`, wip-limit and slot deferrals still count against the cap. There
is no pre-spawn gate for the ten-minute `plan overlap not-before` window; change
1 already keeps those spawns off the cap.

## Tests

- `tests/fly-pool-overlap-defer-uncounted.bh-5912-test.sh` drives
  `bin/fly-pool.sh project-5` end to end (reap cases A1-A5, spawn-gate cases
  B1-B5; B3 runs the real `bin/plan-after.sh`).
- `tests/blocked-resolver-cap-park.bh-5912-test.sh` extracts `br_from_queue`
  and `br_action` from the real script.
