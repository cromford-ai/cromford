# Hub load shed knobs are settings rows; lanes say if they shed (BH-7659)

Doc: OPERATING

## Why

The #7553 (BH-7509) review found three gaps. `hub_load.verdict_max_age_s` and
`hub_load.shed` had no seed row and no catalog entry. The shed lane list was a
fixed string in `bin/lib/hub-load-shed.sh` with an env-only override, so a new
spawning lane did not shed until someone edited that string. And the
`POOL_TICK_MAX_PARALLEL` metadata said `zero_means: null` while the code read
0 as the host's nproc.

## What changed

### Three settings rows

`worker/jobs/schema.d/202610201115-bh-7659-hub-load-shed-knobs.sql` seeds them
with `INSERT OR IGNORE`, so an operator's row survives a re-apply.

| Row | Seed | Order the sampler reads |
|---|---|---|
| `hub_load.verdict_max_age_s` | `1800` | row (positive int) → env `HUB_LOAD_VERDICT_MAX_AGE_S` → 1800 |
| `hub_load.shed` | `on` | row → env `HUB_LOAD_SHED` → on. `off`, `0` or `false` = off |
| `hub_load.shed_lanes` | `catalog` | row (an id list) → env `HUB_LOAD_SHED_LANES` → the catalog's `"sheds": true` lanes → `HLS_SPAWN_LANES` |

The row value `catalog` is no override. A list with an id that is not
`^[a-z0-9][a-z0-9._-]{0,63}$`, or with more than 64 ids, is skipped and the
next rung answers.

Only `bin/hub-load-sample.sh` (hub, every 10 min) reads the rows. It writes
the result into `state/hub-load/verdict` as two more optional fields,
`lanes=<id,id,...>` and `lanes_src=<row|env|catalog|default>`. The line is
still `v=1`. `hls_over` loads them into `HLS_LANES` and `HLS_LANES_SRC`, and
`hls_lane_sheds` uses `HLS_LANES`, then `HUB_LOAD_SHED_LANES`, then
`HLS_SPAWN_LANES`. `bin/project-lane-run.sh` makes no settings call: it reads
the file, then checks the lane. A verdict with no `lanes=` field (written
before this change) behaves as before.

The summary line names the rung that answered:
`max_age_s=<n>(row|env|default) shed_lanes=<n>(row|env|catalog|default)`,
before `shed=...`.

The registry has three knobs on `hub-load-sample`
(`catalog/lanes.d/hub-load-sample.knobs.d/`), each `settable: false`. Set the
row, not the knob:

```bash
bin/jobs-client.sh setting-set hub_load.shed off "why"
bin/jobs-client.sh setting-set hub_load.shed_lanes "alert-triage,blocked-resolver" "why"
bin/jobs-client.sh setting-set hub_load.shed_lanes catalog "back to the catalog"
```

### The `sheds` lane field

A lane file in `catalog/lanes.d` can carry `"sheds": true` (the lane starts no
dispatch while the hub is over) or `"sheds": false` with a `"sheds_why"`.
Today: `sheds: true` on alert-triage, alerts-medic, blocked-resolver,
review-autopilot, review-rescue, stranded-watch and watchdog-responder (the
same 7 as `HLS_SPAWN_LANES`, which stays as the code fallback). `sheds: false`
on dequeue-watch: it clears the merge queue, as BH-7509 decided.

`bin/lane-sheds-lint.sh [root]` checks the field. A lane is DISPATCHED when its
script runs through `bin/project-lane-run.sh` (`pl_dispatch`,
`pl_lane_dispatch`, `llp_dispatch`, `llm-lane-project.sh`,
`project-lane-run.sh`). It is SPAWNING when it is dispatched and has a
`stats.cost_stage`, or its script (or a `bin/<x>.sh` on its dispatch line)
names `run-build.sh`, `agent-call.sh` or `claude-cost.sh`. rc 1 for a spawning
lane with no field, a non-boolean `sheds`, `sheds: false` with no
`sheds_why`, or `sheds: true` on a lane that is not dispatched.
`tests/lane-sheds-field.bh-7659-test.sh` runs it on the repo in CI.

`sheds` is not `shed`. The `shed` key (BH-7616, lane-gate) skips a whole cron
tick of a watermark lane. `sheds` acts only in `bin/project-lane-run.sh`.

### `POOL_TICK_MAX_PARALLEL`

Unset (or no digits) = the host's nproc, as before. `0` = no cap. The registry
entry now says `default: null`, `zero_means: unlimited`, so a console
`.unlimited` row means no cap. No seed row or env value sets this knob, so
production does not change.
