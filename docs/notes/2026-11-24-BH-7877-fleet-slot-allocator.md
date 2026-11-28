# BH-7877: the fleet slot allocator shares pool spawns by weight

Doc: OPERATING

## Cause

Each pool project spawns one machine per queued build, up to its own
`pool_cap`. Nothing shares a fleet total. On 2026-10-21 project-6-os ran 20
machines with a queue of 62 while most other pools sat at 0.

## Change

`bin/fly-pool-tick.sh` runs `pa_tick` (`bin/lib/pool-alloc.sh`) once a tick,
after it lists the pool projects and before `ptb_split`. `pa_tick` writes one
grant file per project. Each project tick (`bin/fly-pool.sh`, fragment
`config/fly-pool.d/3550-fleet-alloc-clamp.sh`) lowers its spawn `BUDGET` to
its grant. The clamp never raises `BUDGET`.

## The rule

1. free = `fleet_slots` minus every live pool machine of the tick's projects (floor 0).
2. demand = queued builds. With a `pool_cap`: min(queued, cap minus live), floor 0.
   Over the daily spend ceiling (`pc_eval` says `over`): 0.
   A spend read that does not answer leaves the demand as it is. The BH-7876
   launch gate still refuses an over-ceiling build.
3. Water-fill: each project with demand gets free x weight / sum of weights.
   A project whose share covers its demand takes its demand and leaves.
   The rest is shared again among the others.
4. Last round: each share is floored. The slots left go one each by largest
   fraction, then larger weight, then name.
5. No grant passes its demand. The sum of the grants never passes free.

Example: fleet 30, A weight 3 queue 50, B weight 1 queue 50, C queue 0:
A 23, B 7, C 0. With an A `pool_cap` of 10: A 10, B 20.

Hotfix rows are not touched (`HOTFIX_EXTRA`): they still spawn past the share.

## Knobs

| row | knob | fallback | meaning |
|---|---|---|---|
| `lane.fly-pool.fleet_slots` | `FLEET_SLOTS` | 0 = off | the fleet total |
| `lane.fly-pool.<project>.weight` | `WEIGHT` | 1 | share weight; a value that is not a whole number of at least 1 reads as 1 |

Both are read from the `.values` of `state/settings-cache.json`, which
`lane_env_apply fly-pool-tick` refreshes at the top of the wrapper. The
allocator makes no settings call of its own. A `registry-seed` row is not in
`.values`, so it does not turn the allocator on. The seed
`worker/jobs/schema.d/202611241817-bh-7877-pool-weight-seed.sql` writes
`lane.fly-pool.project-6-os.weight` = 3 (actor `seed`). No `fleet_slots` row
ships.

## Grant file

`state/fly-pool-alloc/<project>`, one line, written tmp + mv:

    fleet-alloc v1 <epoch> <target> <grant> <weight> <queued> <live> <fleet>

target = live + grant. The clamp sets `BUDGET = min(BUDGET, target - LIVE)`.
The target is a total, so a tick that reads one file twice never spawns the
grant twice. No file, a line that does not parse, or a version that is not
`v1`: no clamp. A fly-placed project gets the file in its lane snapshot
(`catalog/lane-run-inputs.d/fly-pool.ro`).

## Log

One line a tick in `logs/fly-pool.log`, only while the allocator is on:

    2026-11-24 18:00:00Z [pool-alloc] fleet=30 live=0 free=30 a:w=3,q=50,g=23 b:w=1,q=50,g=7 idle=1

One entry per project with queued work; `idle=` counts the rest. A project
tick that the grant lowered says `fleet-alloc: spawning <old>-><new> (target
<t>, live <l>, grant <g>)` under its own `[pool/<p>]` tag.
`bin/pool-tick-summary.sh` reads only `[pool/` lines, so it does not read the
`[pool-alloc]` line.

## Off switches

- No `lane.fly-pool.fleet_slots` row, or 0: no grant, every old file removed.
- `POOL_AUTOSCALE=0`: the same. That kill flag keeps its pre-autoscale promise.

## Known limits

- `pool_stall_tick` and `pool_underuse_tick` (fragment 3500) run before the
  clamp. A project held at 0 by the fleet total can still page "underuse".
- The image lookup in fragment 3500 runs before the clamp, so a project with
  grant 0 still makes those two `flyctl` reads, as it did before.
- A fly-placed project's snapshot is published at most once per
  `POOL_FLY_PUBLISH_MIN_S`. Its grant can be one publish old.

## Check

    grep '\[pool-alloc\]' logs/fly-pool.log | tail -1
