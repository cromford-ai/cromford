# BH-5373 r2: culprit ejection on, bisect off (2026-10-17)

Doc: MERGIFY, MERGE-CONDUCTOR

This note follows `docs/notes/2026-10-13-BH-5373-culprit-flip.md`. That note
says the flip waits. the operator's comment 6229144964 ended the wait.

the operator's RESUME comment (2026-10-17 03:39Z) replaces the 2026-10-15 rule that the
flip waits for 5 matching shadow batches. No live shadow match was proven
before this flip. The risk evidence is the replay table in the 2026-10-13 note.

What changed:

- `config/mergify/repos/cromford.conf`: `batch_failure_attempts=0`.
  `.mergify.yml` `default` queue: `batch_max_failure_resolution_attempts: 0`.
  `hotfix` and `solo` are unchanged.
- `catalog/lanes.d/merge-conductor.json`: `MC_BATCH_IMPACT` default 1 -> 2.
- `bin/lib/mc-batch-eject.sh` is unchanged. `bej_reentry_gate` already skips
  the solo re-run when the map names exactly one PR.

Known risk: the replay found an `unknown` answer on 6 of 16 drafts. With
bisect off, those drafts go to the solo re-run. A solo verdict of `pending`
or `could-not-run` re-queues the member.

Rollback:

1. Set the row `lane.merge-conductor.cromford.mc_batch_impact=1`.
2. Delete `batch_failure_attempts=0` and re-render `.mergify.yml`.

Still owed (operator steps, not in this PR):

- `MERGIFY_CI_KEY` on the hub (NEEDS_HUMAN in ALERTS.log), then the parallel
  flip: `queue_mode=parallel` and `queue_partition.mode=enforce`.
- `queue_risk.mode=enforce` (6200544511) is a BH-5430 settings row.
- If the row `lane.merge-conductor.cromford.mc_batch_impact` exists with
  value 1, delete it or set it to 2. This box cannot read the hub rows.

Evidence for LIVE: the first `BATCH_IMPACT_* ... mode=2` line in the hub's
`logs/merge-conductor.log`.
