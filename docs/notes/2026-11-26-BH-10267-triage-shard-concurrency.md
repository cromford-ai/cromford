# BH-10267: a triage tick prepares its tickets at the same time

Date: 2026-11-26. Ticket: example-org/cromford #10267.

## The problem

`bin/lib/rt/shards.sh` starts one detached session for each ticket. The
sessions already ran at the same time. The work for each ticket BEFORE its
session starts did not: the fingerprints, the running-build check and the
overlap verdict ran for one ticket, then the next. On project-3 on 2026-11-26
the shards of one tick started 100 to 180 seconds apart, the tick held the
project lock for 7 to 32 minutes, and the next cron ticks stopped at
"previous run still active".

## The change

- The checks for one ticket are the function `_rt_shard_prep`. The tick runs
  it for `TRIAGE_SHARD_CONCURRENCY` tickets at the same time (default 20) and
  waits for them. The lines of the checks did not change.
- The caps and the start of the session stay in one loop, one ticket at a
  time, in the scope order: the in-flight cap, the per-hour shard line and the
  per-hour dollar line read and write their counters as before.
- One tick starts at most that number of sessions. It counts this tick of
  this project only: shards of other projects and older shards do not count
  (`TRIAGE_SHARDS_MAX` stays the box ceiling, off by default). Before, a tick
  had no limit, and the slow loop was the limit in practice. A ticket over
  the number is left in scope and offered again on the next tick.
- All tickets of a tick are prepared before the first session starts, so a
  fingerprint can be up to one prepare round old at the session start. The
  next tick's board read covers a comment that lands in between.
- Free-memory guard: the number for a tick is at most `MemAvailable` divided
  by `TRIAGE_SHARD_MEM_MB` (default 300), never under 1. The tick logs
  `concurrency lowered <row> -> <n> for this tick`. It never fails a tick.
- One shard for each ticket: the key list has each key one time, the prepare
  step skips a key whose lock is held, and `bin/triage-shard.sh` takes
  `locks/triage-key-<project>-<KEY>.lock` with `flock -n` (not changed).

## Settings rows

| row | default | meaning |
|---|---|---|
| `lane.run-triage.triage_shard_concurrency` | 20 | fleet value, 1 to 100; 1 = one ticket prepared at a time and one session for each tick (the kill switch) |
| `lane.run-triage.<project>.triage_shard_concurrency` | none | value for one project; wins over the fleet row |
| `lane.run-triage[.<project>].triage_shard_mem_mb` | 300 | free MB for each shard; 0 = no memory guard |

The row name follows the knob registry (`lane.<lane>.<knob>`), so the ticket's
`triage.shard_concurrency` is `lane.run-triage.triage_shard_concurrency`.

## Not changed

The work of a tick before the shard step (the board read, the triage-state
pass, merged-ticket-advance) still runs one step after another. On project-3
that part took about 7 minutes of a tick on 2026-11-26.

## Proof

`tests/triage-shard-concurrency.bh-10267-test.sh` runs the real
`bin/run-triage.sh` with a stub that makes the work for each ticket take 2
seconds: 6 tickets take under 8 seconds (13 seconds before the change).
On a live box: `grep "dispatched .* shards" logs/<project>.log` and the time
between the tick start and the next tick that is not "previous run still
active".
