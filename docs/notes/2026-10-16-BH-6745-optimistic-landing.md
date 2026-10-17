# Direct merge in optimistic landing mode (BH-6745, wave 2 of #6541)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

With `MC_LANDING_MODE=optimistic`, the merge conductor merges an eligible
READY PR on a Mergify repo directly. It does not add the `merge-queue` label.
The default mode stays `queue`, so nothing changes until an operator sets the
settings row.

- `bin/lib/mc/landing.sh` gains `landing_direct_on`, `landing_direct`,
  `landing_direct_budget` and `landing_direct_path`. `landing_shadow` now uses
  the shared `_landing_record`, with the same line, row and mark as before.
- `bin/merge-conductor.sh` `pr_worker` READY arm: before the Mergify enqueue,
  `landing_direct` runs when `landing_direct_on` holds (mode `optimistic`,
  provider `mergify`, not a lane-run machine). Its rc decides the arm:
  - rc 0 `merged`: `conductor_settle` with `by:conductor (direct landing)` and
    the merge sha. No enqueue, no label.
  - rc 1 `queue`: the enqueue runs exactly as before.
  - rc 2 `budget`, rc 3 `lock`, rc 4 `<code>`: the merge budget unit goes
    back, the row stays READY with reason `budget`, `merge-lock` or
    `direct-failed`. rc 4 is no `mergefail` strike.
- The merge is `mc_merge` (`gh_pr_merge_rest`, bound to the head sha) under
  `mc_merge_locked`, the per-project merge lock.
- A refused merge (405, 409, 422, `error`) writes
  `landingfail <key> <head> <code>` on the attempts ledger. The next tick sees
  it, logs `<key> LANDING_DIRECT fallback=queue`, and enqueues.
- `landingdirect <key> <head>` is written under the lock, just before the
  merge PUT. `mc_settle_merged` (`bin/lib/mc/settle.sh`) writes the ledger merge
  row with detail `merge-conductor path=direct` when that mark is there and no
  `landingfail` is. Every other landing keeps `merge-conductor`.
- The result goes on the decision row: new nullable columns
  `landing_decisions.outcome` and `outcome_at` (`ADDED_COLUMNS` in
  `worker/jobs/src/lib/core.js`), set by
  `PUT /api/landing-decisions/outcome {repo, number, head, mode, outcome}`
  (`worker/jobs/src/routes/landing-outcome.js`). `outcome` is one of
  `merged|405|409|422|error|budget|lock`. 200 on one row, 404
  `no decision row`, 400 on a bad field. `GET /api/landing-decisions` returns
  both columns. The UPDATE uses the UNIQUE (repo, number, head, mode) index.
- New knob `MC_DIRECT_MERGE_BUDGET` (default 6, 0..50, 0 = off).

## Landing modes

| mode | what the conductor does with a READY PR on a Mergify repo |
|---|---|
| `queue` (default) | Enqueues it (label). Reads and records nothing new. |
| `shadow` | Enqueues it. After the enqueue, records one `LANDING would=direct\|queue reason=<token>` line and one `landing_decisions` row per head. |
| `optimistic` | Records the decision first. If `landing_eligible` says `ok`, merges it directly, bound to the head, with no label. Else enqueues it as in `queue`. |

- Budget: `MC_DIRECT_MERGE_BUDGET` caps direct merges per project per tick.
  Row `lane.merge-conductor[.<project>].mc_direct_merge_budget`.
  `MC_MERGE_BUDGET` still caps every landing per tick, so the direct merges in
  one tick are at most min(`MC_MERGE_BUDGET`, `MC_DIRECT_MERGE_BUDGET`). An
  eligible PR over the budget stays READY (reason `budget`) and is tried again
  on the next tick. 0 turns direct merging off: every PR enqueues.
- A PR that already has the `merge-queue` label stays with the queue.
- GitHub's native queue (`provider github`) and repos with no queue do not
  change in any mode.
- Rollback: set `lane.merge-conductor[.<project>].mc_landing_mode` to `queue`.
  The next tick enqueues every READY PR.

## How to check it

1. Run `HARNESS_TEST_SANDBOX=1 bash tests/landing-direct.bh-6745-test.sh`.
2. Run `cd worker/jobs && node --test test/landing-outcome.bh-6745.test.js`.
3. On the hub, run `grep 'LANDING_DIRECT outcome=' /root/harness/logs/merge-conductor.log | tail -5`.

Out of scope: CI and deploy on main after a direct merge (wave 3), reverts
(wave 4), the report and the flip (wave 5).
