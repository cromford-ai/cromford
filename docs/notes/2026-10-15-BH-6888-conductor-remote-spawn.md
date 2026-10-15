# A machine's conductor rebase as a queued pool job (BH-6888 C0, BH-6881.4)

Doc: MERGE-CONDUCTOR

## What changed

On a lane-run machine (`MC_ON_MACHINE=1`, set by `bin/merge-conductor-pr.sh`)
the conductor can now enqueue its rebase as a pool job. Before this change, it
always wrote `rebase` to `MC_PR_DEFERRED_FILE` and the hub ran the PR again.
The code ships dark: the switch row is seeded `0`.

- **Switch.** The settings row `conductor_remote_spawn.<project>` wins when it
  has a row, else `conductor_remote_spawn`. Only the exact value `1` is on. The
  project must also have a pool app (`routing_pool_app`, else
  `flags/fly-pool-app-<project>`). A failed read is off.
- **Spawn.** `mc_rebase_spawn` and `mc_pool_rebase_enqueue`
  (`bin/lib/mc/rebase.sh`) call `mc_remote_rebase_spawn`
  (`bin/lib/mc/spawn-remote.sh`). It reads the `build_queue` row
  `RB-<pr>-<head8>` first, then puts at most one row. The meta is the hub's
  pool rebase meta plus `dedup` (`<project>.<pr>.<head12>.rebase`) and
  `by:"machine"`. No file is written under `state/`.
- **Outcome map.** `queued`/`claimed`, enqueued less than
  `MC_REBASE_POOL_TIMEOUT_SECS` (default 5400s) ago: in flight, rc 0. Older,
  or with no `enqueued_at`: stale, the same bound as the hub pool path. `done` with
  `REBASED`, `CONFLICT`, `GATE_RED` or `REBASE_LEASE_REJECTED`: on record,
  rc 4. `failed`, or `done` with `REBASE_SETUP_FAILED`: put again while the
  row's `attempt` is below `conductor_remote_retry_max` (seeded 3). `done`
  with an empty or unknown reason, `dropped`, a stale row, the cap, and every
  read or put failure: rc 3 and the `rebase` deferred word, so the hub runs the PR as
  before.
- **Consume.** `rebase_consume` reads the same row through
  `GET /api/queue`. A `CONFLICT`, `GATE_RED` or lease rejection goes through
  `rebase_result` once per (PR, head). A `REBASED` logs the new sha and lets
  the classifier read the head GitHub lists. A `failed`, empty, stale or
  `dropped` row clears the NEEDS_REBASE arm's `rebase <key> <head>` mark
  (`mc_remote_rebase_reopen`). The arm then calls the spawn in the same tick,
  and the spawn puts the retry or hands the PR back. Without this, the mark
  (a pr-state row that outlives the machine) stopped every retry and every
  hand-back until the NEEDS_REBASE TTL.
- **Unchanged.** The hub (`MC_ON_MACHINE` unset), and a machine with the
  switch off. Re-review (C1) and deploy-verify (C2) still defer on a machine.

## How to turn it on or off

`conductor_remote_spawn.<project>=1` turns it on for one project. Set it to
`0` (or delete the row) to turn it off. No deploy is needed.

## Proof after a switch flip

`grep -c 'remote rebase queued' logs/merge-conductor.log` on the machine
runs is above 0. A `deferred to the hub (<why>)` line names each hand-back.
