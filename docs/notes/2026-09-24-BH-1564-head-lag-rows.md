# The head-lag record is `headlag` rows, and a held verdict is cached per tip

Doc: MERGE-CONDUCTOR

## What changed

BH-1529's per-PR record, `state/merge-conductor/head-lag/<pr>`, lived on one box.
A wiped state dir, a hub move or the 3-day GC could lose it. A PR still lagging on the same
tip then got a fresh clock, a second close/reopen and a second HEAD_LAG page.

Every change to the record now also writes a `pr_attempts` row (BH-1025). Each row has kind
`headlag` and holds one fact. Its sha column is `"<tip> <fact> [n]"`, and the facts are:
`seen`, `try <n>`, `reopened`, `closed`, `refused <n>`, `gaveup`, `alerted` and `held`.
`bin/lib/mc/rebase.sh` lists them. The rows go through `mc_attempt_row_put`, which is the row half
of `mc_attempt_put`, split out unchanged. It uses the same `pr-state-rows` flag and the same
per-tick latch.

The file is still read first, as a cache. When the file does not hold the tip being looked at, one
`pr_attempt_list` GET reads that PR's `headlag` rows. The rows rebuild the record, and the file is
written back. The rows are asked only in these cases:
- after a wipe
- after the GC
- on the first sighting of a new tip

The `try` row is written before `mc_kick_ci`, so a restart can never buy a tip a second reopen.

A HELD answer from `to_lane_hold` / `mc_hold_keeps_pr` is now cached per tip. It is stored as a
new eighth file column and as a `held` row, and it lasts for `MC_HEAD_LAG_HELD_RECHECK_MINS`
(a registered knob, default 60; 0 asks every tick). A held PR that keeps lagging is therefore not
re-read every tick, and a lifted hold still gets its kick within the window.

## Why

Ticket #1564 (F4 of the #1562 review) holds that state lives in the database. The goal is
"no double reopen after a hub restart" and "the attempt survives a wiped state dir".

## How it is pinned

`tests/mc-head-lag-rows.bh-1564-test.sh` drives the real conductor against a curl shim that keeps
a real pr_attempts store. It checks these cases:
- wipe the whole conductor state dir between the kick and the next window
- wipe it again after the page
- GC only the file
- a held tip over several ticks and a wipe
- the worker down
- the flag down

It also checks the `pr_attempt_list` rc contract. With the flag down, no request is made.
