# BH-8886: a build key's GATE_RED is a build result, and a refused rebase apply closes its row

Doc: FLY-POOL

## What failed

On 2026-11-01 02:50Z the hub reaped the pool RESULT of build BH-8817:
`GATE_RED 7 red: ...`. The pool reap arm `# >>> pool rebase reap`
(`config/fly-pool.d/3400-pool-listing-and-reap.sh`) matched the word
`GATE_RED` for any key, so it called `mc_pool_rebase_apply`. That function
reads only `RB-` keys and answered rc=1. The refused branch left the queue
row CLAIMED on purpose. BH-7382's orphan-row release then freed the row at
02:50:56Z, and fly-dispatch spawned a new machine for BH-8817 at 03:02:11Z.
That was the 5th spawn of BH-8817 since 2026-10-31. BH-8883 did the same at
08:20:53Z.

Since BH-8062 a normal build writes `GATE_RED <n> red: <suites>; see
<build>/gate.txt` from its selection gate, and BH-7365 writes
`GATE_RED migration-number: ...`. So the word alone does not mean "rebase".

## What changed

1. The rebase reap arm runs only for an `RB-` key. A build key's `GATE_RED`
   falls through to the build path: the row closes `done` with the RESULT as
   the reason, the record goes to `state/remote-results/<p>/<KEY>.json`, and
   the relay carries it to the owning box.
2. Any other rebase word (`REBASED`, `CONFLICT`, `REBASE_*`) on a key that is
   not `RB-` closes the row `failed` ("rebase word on a non-rebase key"), with
   one ALERTS line. Nothing is applied or relayed.
3. An `RB-` apply that answers non-zero (1, or the seeded 127 when the lib is
   not on the box) closes the row `failed` with the reason
   `APPLY_FAILED rc=<n>: <first 120 bytes of RESULT>`. When the lib is loaded,
   `mc_pool_rebase_fail` marks the hub rebase job file failed, so the merge
   conductor's failed arm reaches the PR on its next tick. No row stays
   CLAIMED, so the orphan-row release does not free it and nothing re-spawns.
4. The blocked resolver reads a rebuild that ended `GATE_RED` as
   `rebuild-gate-red` (`br_rebuild_outcome`, `bin/lib/br/discovery.sh`).
   The ladder maps it to `abandon-rebuild`, the same ticket-level stop as
   `rebuild-plan-blocked` and `rebuild-review-blocked`. Before, it answered ""
   and the resolver waited on "rebuild already in flight" every tick.

## The per-ticket spawn cap

The ticket also asked for a cap on pool spawns per ticket per 24 h. That cap
is already on main (BH-1075, BH-7190): `pool_spawn_cap_load` and
`pool_spawn_cap_check` in `config/fly-pool.d/0100-head.sh`, read from
`lane.fly-pool.<p>.pool_spawn_cap_per_key`, then `pool_spawn_cap_per_key`,
then env `POOL_SPAWN_CAP_PER_KEY`, then the fallback 2, over the window
`pool_spawn_cap_window_s` (fallback 86400). Over the cap it writes one
`POOL_SPAWN_CAP_WAIT` ALERT per episode. It did not stop BH-8817 because
cromford sets the row to 24 (docs/FLY-POOL.md, BH-7190). This change
adds no knob and changes no row value.

## Tests

- `tests/pool-gate-red-build-key.bh-8886-test.sh` drives the real
  `bin/fly-pool.sh` reap for each key and word.
- `tests/br-rebuild-gate-red.bh-8886-test.sh` drives the resolver's
  classifier, ladder and row close.
