# 2026-11-04 — BH-8880: no machine for a key that waits on another key's open PR

Doc: FLY-POOL

## What happened

project-5 TK-3786 waits on TK-3785 (PR #3958, open and BLOCKed since
2026-10-20). Each pool machine planned, saw the same overlap, recorded
`BUILD_DEFERRED After: TK-3785 PR #3958 open` (or `OVERLAP_DEFER`) and was
destroyed. The next tick spawned again, up to the 12-per-24 h cap, every day:
196 DEFERRED records, 189 spawns, $14.22 of machine time, 0 builds.

`pool_after_gate` (BH-5967) holds a row only while its queue file carries
`after`. The ceiling release drops that field, and a row written again has
none. Nothing read the key's BUILD_DEFERRED hub record before a spawn.

## The rule

`pool_spawn_decision` calls `dfs_stop_check` (`bin/lib/defer-after-stop.sh`)
right after `pool_after_gate` and before the HOLD gate and the spawn cap.

1. The gate reads the key's newest hub record
   (`builds/pool-<p>-<key>-*/RESULT`, greatest mtime).
2. If line 1 starts `BUILD_DEFERRED ` and names another plain key (`After:
   <KEY>`, else `OVERLAP_DEFER <key> vs <KEY>` with any `-rN` dropped), and
   that key has an open PR in the tick's open-PR list, the row is held.
3. A held row gets no machine and one fly-pool.log line:
   `skipping <key>: waits on <KEY> PR #<n> open — no machine`.
   The row stays queued. There is no QROW write, no deferral count and no
   spawn-cap count.
4. An open-PR list that does not answer holds the row this tick, with the line
   `... the open-PR list did not answer — retried next tick, no machine`.

The open-PR list is the one `pool_pr_bulk_read` or `pr_open_for_key_any_rest`
reads once per tick. The gate adds no list read.

## Release paths

- The blocker's PR merges or closes: the next tick spawns.
- A person comments on the ticket after the record (GitHub-Issues projects
  only): the gate writes `<record>/defer-after.released`, says one `RELEASED`
  line, and the key spawns. The comments are read only when the tick's ai-build
  listing shows the issue changed after the record. A read with no person
  comment writes `<record>/defer-after.seen` with the listing's `updated_at`, so
  the same listing reads no comments again.
- A newer record that is not such a deferral.
- A mutual wait (the blocker's newest record names this key) is not held by
  this gate. `pool_after_gate` and the machine's plan-after rule decide it.

## Knob

`POOL_DEFER_AFTER_STOP` (fly-pool lane knob, default 1; 0 turns the gate off
with no deploy).

## Open question (plan assumption A2)

After the 360-minute ceiling, `pool_after_gate` still alerts "the hold is
released and the ticket is offered again". With this gate, a row whose blocker
PR is still open is then held here instead. The alert text is not changed.

## Test

`tests/pool-defer-after-stop.bh-8880-test.sh` drives `bin/fly-pool.sh` with
stub records and a stub open-PR list (cases D1-D12, G).
