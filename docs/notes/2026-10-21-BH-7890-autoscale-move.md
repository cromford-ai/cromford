# BH-7890: the autoscale decision leaves the pool tick wrapper

Rest of BH-7433. Spec: `docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md`
section 4, S6 ("hub processes per pool tick 14 to 1").

Doc: BUILD-CONCURRENCY, verification-map/fly-pool-sweep

## What changed

`bin/fly-pool-tick.sh` now classifies the projects first. The flag loop only
collects the pool projects, and `ptb_split` (BH-7432) runs in both
`POOL_AUTOSCALE` modes. The wrapper runs `bin/fly-lock-guard.sh` and reads
`bin/pool-cap.sh --autoscale` only when `PTB_HUB` is not empty. Then `AS=0`
ticks `PTB_HUB` in sequence, and any other answer starts it in parallel
(`tick_start_capped`). The onboard drain runs the guard once before it launches
`bin/fly-onboard.sh`. The guard runs at most once per wrapper run
(`tick_guard_once`).

For a fly-placed project the wrapper makes no parallelism decision. The
lane-fleet autoscaler (`bin/lane-fleet.sh` `lf_decide`, BH-6885) decides how
many lane machines run its `fly-pool` rows. That code did not change.

Before this change `POOL_AUTOSCALE=0` skipped `ptb_split`: every project got a
hub `bin/fly-pool.sh` start, in sequence, also when it was placed fly.

## Definition of the metric

"Hub processes per pool tick" here is the wrapper itself plus the children it
starts on the S6 path: one `bin/fly-pool.sh` per project, `bin/fly-lock-guard.sh`
and `bin/pool-cap.sh --autoscale`. The fixture is 13 pool projects, all placed
fly, no live rows. The spec's "14" is 1 wrapper + 13 project ticks. The spec
did not measure it.

The rows-parity pass (BH-2522) and the budget pass (BH-7190) are fixed
children on every tick. The S6 list does not name them and this change keeps
them. They are on their own row below, so the "1" is not rounded up.

## Before and after

Source: the `bh7890:` lines of `tests/fly-pool-tick-autoscale-move.bh-7890-test.sh`.
"Before" is the suite run on the origin/main wrapper (8a1d9bc7) before the
edit. "After" is the same suite on this branch.

| mode | wrapper | fly-pool.sh | fly-lock-guard.sh | pool-cap.sh --autoscale | hub processes (S6 path) |
|---|---|---|---|---|---|
| AS=1, before | 1 | 0 | 1 | 1 | 3 |
| AS=1, after | 1 | 0 | 0 | 0 | 1 |
| AS=0, before | 1 | 13 | 1 | 1 | 16 |
| AS=0, after | 1 | 0 | 0 | 0 | 1 |

| mode | parity | budget | forks (stub guard) |
|---|---|---|---|
| AS=1, before | 1 | 1 | 242 |
| AS=1, after | 1 | 1 | 240 |
| AS=0, before | 1 | 1 | 1007 |
| AS=0, after | 1 | 1 | 240 |

The fork column uses a stub guard of 1 fork. The real guard is about 295 forks
per run (`docs/notes/2026-10-19-BH-7433-tick-wrapper-trim.md`, per-component
table) and the real `pool-cap.sh` about 8. On the hub an all-fly tick so saves
about 300 forks with `AS=1`, and with `AS=0` it also saves the 13 sequential
`fly-pool.sh` runs (767 forks in the fixture).

Not changed: a project with no fly placement row (every project in prod today,
`pp_none_fly`) still goes to the hub. That tick still runs the guard, the
`--autoscale` read and the start, as before (suite cases A3 and A4).

## Not measured here

- The hub's real process count on a live tick. This box has no hub. The
  numbers above come from the scratch fixture.
