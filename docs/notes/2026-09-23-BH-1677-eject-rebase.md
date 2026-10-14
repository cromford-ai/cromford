# BH-1677: a Mergify base-conflict ejection is rebased, not struck

Doc: MERGE-CONDUCTOR

## What changed

- `mc_dequeue_conflict` (`bin/lib/mc/queue.sh`) is live. It reads the PR's issue
  comments (the same `gh_rest_issue_comments` read as `mc_dequeue_reason`), takes
  the newest `mergify[bot]` comment, and answers `base-conflict` when its
  `## Reason` section says "conflicts with the base branch" or "base branch
  conflict". An unreadable read, no Mergify comment or no match answers `""`.
- The settle pass of `bin/merge-conductor.sh` (Mergify only) calls
  `mc_eject_conflict_note` when it records an ejection. A `base-conflict` answer
  appends `ejectconflict <key> <head>` to `attempts.txt` once and logs
  `EJECTED_CONFLICT <key> <head>`.
- Both strike counts (the settle pass and the READY arm's re-entry block) go
  through `mc_eject_strikes`. It leaves out `ejected`/`reejected` lines on a head
  marked `ejectconflict`, so two base-conflict ejections no longer park the row
  `queue-ejected-twice`.
- The NEEDS_REBASE arm asks `eject_rebase_arm` (`bin/lib/mc/rebase.sh`) first. A
  head marked `ejectconflict` with no `ejectrebase`, no `rebase` mark and no job
  file gets one rebase ahead of `MC_REBASE_BUDGET` and the merge-tree test. The
  hub spawn is capped by `MC_LAND_REBASE_PARALLEL`. `ejectrebase <key> <head>` is
  written before the spawn and removed when nothing was spent (cap refusal, spawn
  failure, pool queue unreachable), and the next tick offers it again. A
  successful spawn also writes the ordinary `rebase <key> <head>` mark. Log words:
  `EJECT_REBASE_SPAWNED`, `EJECT_REBASE_DEFER`, and `would EJECT_REBASE` when the
  merge flag is off.
- When that rebase pushes a new head, the conductor writes one
  `job_ledger_put rebase <url>@<new-head> REBASED "rebased_after_ejection=1 from=<old8>"`
  (fail-open), logs `EJECT_REBASED <key> <old8> -> <new8>`, and marks
  `ejectrebased <key> <old-head>` so it happens once. It fires from
  `rebase_consume` when the tick reads the job itself, and from
  `eject_rebased_moved` when GitHub already lists the pushed head (the job file
  is keyed by the old head, so `rebase_consume` never reads it then).
- The re-enqueue is the ordinary path: WAIT_CI, READY, enqueue. No new state.
- `MC_EJECT_REBASE` is registered in `catalog/lanes.d/merge-conductor.json`.
  `MC_EJECT_REBASE=0` reads no comment, writes no mark, spawns nothing and counts
  every ejection as a strike, as before BH-1669. Marks already written buy nothing
  at 0.

## What it supersedes

`docs/MERGE-CONDUCTOR.md` §8 still calls `MC_EJECT_REBASE` reserved and
`mc_dequeue_conflict` a stub (BH-1676). Both are live now. A later `docs:` pass
rewords §8. The native queue (`PROVIDER=github`) is unchanged: it has no Mergify
dequeue comment to read, so its ejections are still strikes.

## Why

A PR that conflicts with the base was ejected, rebased or pushed, and ejected
again on its new head: two strikes, `queue-ejected-twice`, and a full rebuild by
`bin/blocked-resolver.sh`. With the tick's rebase budget spent, the DIRTY PR sat
in NEEDS_REBASE meanwhile. A textual conflict still ends `conflict-unresolvable`
and goes to the resolver; the per-head marks mean it does not loop.

Pinned by `tests/eject-rebase.bh-1677-test.sh`.
