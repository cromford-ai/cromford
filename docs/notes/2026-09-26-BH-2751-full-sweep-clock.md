# The daily full triage sweep comes back: only a full tick stamps the clock (BH-2751 part 2, BH-2753)

Doc: TRIAGE

## Cause

`bin/triage-gate.sh` step 4 answers `RUN daily-sweep` when
`now - state/<project>.gate-meta >= FULL_SWEEP_SECS` (86400 by default).
That file is written by `rt_gate_consume` in `bin/lib/rt/gate.sh`. Before this
change it wrote `date +%s` there on every call. It has three callers:

- `bin/lib/rt/shards.sh`, when a sharded tick dispatches. That tick is always
  scoped, because shards are off when `SCOPE_N=full`.
- `bin/lib/rt/launch.sh`, on every rc=0 single-session tick, whatever its scope.
- `rt_gate_fail_consume` in `bin/lib/rt/gate.sh`, the BH-1021 fail cap.

So every scoped tick (event-wake, board-changed with a diff, queue-pending,
results-sweep) pushed the full-sweep clock forward. A board that gets a wake
more often than once a day never reached step 4. cromford had no daily
sweep after 2026-09-24.

## Fix

`rt_gate_consume` stamps `gate-meta` only when `SCOPE_N` is `full`. Unset counts
as `full`, so a caller that never sets it (the unit suites, anything sourcing
`gate.sh` bare) keeps the old behavior. It still always moves
`gate.pending` into `gate.json` and still calls `tgl_put_gate`, so the
fingerprint and the BH-2318 ledger row behave as before. The ledger row mirrors
whatever `gate-meta` holds, so a scoped tick now mirrors the unchanged epoch.

A scope arm that falls through (a queue-pending tick with an empty queue, a
wake whose diff was unusable, board-changed with an empty diff) keeps
`SCOPE_N=full` and runs the full SOP, so it still stamps. That is correct: the
board was enumerated. The BH-1021 cap on a scoped tick now absorbs without
stamping. Its no-pending shape (daily-sweep, forced, no-gate-state) is a full
tick, so it still stamps and still ends its own loop.

`bin/triage-gate.sh` is unchanged. The ticket asked for its step-4 check to
move above arm 2 only if the live `gate-meta` on box-small turned out
to be older than 24h. The build box could not reach that host (hostname does
not resolve, and its fleet.conf address is unreachable), so the move was not
made. To check the live clock:

```
ssh box-small 'cat /root/harness/state/cromford.gate-meta; date +%s'
```

If the first number is more than 86400 below the second and the gate still
never answers `daily-sweep`, a gate arm above step 4 is firing every tick. That
is the case the reorder would fix.

## Pinned by

`tests/triage-full-sweep-clock.bh-2751-test.sh` drives the real
`bin/run-triage.sh` for a sharded event-wake, a queue-pending session and a
board-changed session, then asks the real `bin/triage-gate.sh` for its answer.
It also covers a full daily-sweep tick and the function on its own (unset
`SCOPE_N`, and the ledger call on a scoped consume).
