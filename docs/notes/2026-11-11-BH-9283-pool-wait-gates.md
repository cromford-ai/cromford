# 2026-11-11 — BH-9283 (slice C0): pool wait gates see stack-wait, re-check on growing delays, get a time limit, count as held

Doc: FLY-POOL

This extends the BH-8880 gate (`docs/notes/2026-11-04-BH-8880-pool-defer-after-stop.md`, `bin/lib/defer-after-stop.sh`).

## What happened

project-6, 2026-11-04 to 2026-11-08: TK-3660 stood down `BUILD_DEFERRED
stack-wait: parent branch ticket/TK-3659 ...` six times in 50 minutes, and each
stand-down cost one Fly machine, because the gate read only `After:` and
`OVERLAP_DEFER`. TK-3577 was held 5498 minutes with no limit and no alert, and
the fleet page counted it as queued (`oldest_queued_min=5498`).

## What holds a row

`_dfs_blocker` reads the blocker with `defer_wait_key`
(`bin/lib/deferral-after.sh`). First match wins:

| RESULT line 1 | blocker | kind |
|---|---|---|
| `After: <KEY>` | `<KEY>` | after |
| `OVERLAP_DEFER <key> vs <KEY>[-rN]` | `<KEY>` | after |
| `stack-wait: ... ticket/<prefix>-<n>[-rN] ...` (not the own key) | `<PREFIX>-<n>` | stack |
| `Blocked-by #<n>` | `<own prefix>-<n>` | blocked |

A self key, a child key (`N.M`), a lower-case key, a non-ticket branch and a line
that is not `BUILD_DEFERRED` hold nothing. `defer_after_key` is not changed, so
the reap paths in `bin/fly-pool.sh` and `bin/jobs-watchdog.sh` keep the
After-only rule.

## Re-checks

The wait line `state/pool/<p>/<KEY>.dfs-wait` holds
`<blocker> <kind> <since> <checks> <next_at> <alerted_at>` (tab separated,
epochs). The clock starts at the first held tick and restarts when the blocker
changes. After check `c` the next open-PR read is due
`min(POOL_WAIT_RECHECK_MIN * 2^(c-1), POOL_WAIT_RECHECK_MAX_MIN)` minutes later:
10, 20, 40, 80, 160, 240, 240 ... A tick that is not due holds the row with no
read and says `skipping <KEY>: waits on <BLK> <PR> — no machine; next re-check
HH:MMZ`. The person-comment release runs on every held tick. An unreadable list
holds the row and changes nothing, so the next tick reads again.

## Time limit and alert

Kind `stack` uses `STACK_WAIT_CAP_H` (hours, `sw_cap`). Kinds `after` and
`blocked` use `POOL_AFTER_MAX_MIN` (minutes, 360; 0 = no limit). At the limit
the record gets `defer-after.released`, the clock restarts for the same
blocker, the row spawns, and the pool log says `RELEASED <KEY>: wait limit`.
One `WAIT LIMIT` ALERTS line names the key, the blocker, the PR and the knob.
It is written once per key and blocker: a second limit pass on the same blocker
does not page again. A new blocker, or a blocker that merges, resets it.

## Held on the fleet page

A held row writes `state/pool/<p>/<KEY>.held` (the BH-1461 shape, `why`
`defer-after: waits on <BLK> <PR> (<kind>)`) and, once per hold, the
`pool_holds` row. `bin/fleet-status-push.sh` already counts both as held and
leaves the row out of `oldest_queued_min`. A release removes only a marker
whose `why` starts `defer-after:`. A hold never overwrites a marker another
gate wrote.

## Knobs

`POOL_WAIT_RECHECK_MIN` (10; 0 = every tick) and `POOL_WAIT_RECHECK_MAX_MIN`
(240), fly-pool lane knobs. The kill switch is still `POOL_DEFER_AFTER_STOP=0`.

## Not in this slice

- The `.dfs-wait` line is a file only. `dfs-wait` is not in the `pool_markers`
  allow-list (`bin/lib/pool-state-rows.sh` `_PSR_MARKER_RE`,
  `worker/jobs/src/routes/pool-markers.js`), so a failed-over hub starts the
  clock again at its first held tick.
- Fix 3 (wait deferrals do not count toward `JOBS_QUEUE_DEFER_MAX`), fix 5
  (`blocked-resolver` skips a FAILED row whose blocker is open) and fix 7
  (a stacked child with foreign commits goes to draft) are later slices of
  #9283.
- No sweep deletes the `.dfs-wait` line of a ticket that closed while held.

## Test

`tests/pool-wait-gates.bh-9283-test.sh` (P1-P14, W1, S1-S2, R1-R5, L1-L5,
H1-H4, E1, E5, G).
