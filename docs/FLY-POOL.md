# Fly pool: every knob that can hold a build (BH-7190)

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here.
<!-- changes:end -->

Read this page when a build waits and you ask: which number holds it?
Values below were read on the hub on 2026-10-16 (settings API, `flags/`, `fly/`, `env/global.env`).
Run `bin/concurrency-plan.sh <project>` for the live answer. Run `bin/pool-never-wait-seed.sh` to see which rows differ from this page.

## Policy

1. The pool has **no slot cap**. `bin/pool-cap.sh` prints `0` (unlimited). The spawn budget of a tick is the queue depth.
2. Money bounds the pool, not a slot count. Each project has a daily **machine-hour budget** that alerts at 80% and at 100%. It never stops a machine (the operator: tripwires alert only).
3. A build must not wait on a number we chose. A number that can still hold a build is listed here, with its value and its cost.

## Cost per machine-hour

A pool machine is `performance-8x` with 16 GB (`machine run` in `bin/fly-pool.sh`).
Price: 8 cores x $31 + 16 GB x $5 = $328 a month. A month is 730 hours (`catalog/fly-prices.json`).

| Unit | Cost |
|---|---|
| 1 machine-hour | **$0.449** |
| 1 machine for 24 hours | $10.78 |
| 100 machine-hours | $44.93 |
| Fly spend ceiling, whole fleet (`spend.ceiling.fly-pool.day_usd` row) | $2,628.39 a day, alert only |

A machine costs the same while it works and while it waits. An orphan slot (BH-7107) costs money and builds nothing.

## Knobs that can hold a build

"Holds" says how the knob stops a build. "Now" is the value on the hub on 2026-10-16.
"Never wait" is the value this ticket sets for `project-6-os` and `cromford`.

| Knob | Where it lives | Holds | Now | Never wait | Cost |
|---|---|---|---|---|---|
| `POOL_CAP` (row `lane.fly-pool.<p>.pool_cap`) | settings row | A project may not exceed N live machines. 0 = unlimited. | no row, `flags/fly-pool-<p>` has no number, `fly/pool-caps.conf` has no line: unlimited | explicit row `0` for both. A row of 0 also beats a later `pool-caps.conf` line. | $0.449 per extra machine-hour |
| `flags/fly-pool-<p>` | hub flag file | Presence enables the pool. A number inside it is a hard cap. | present, empty, for both | unchanged | none |
| `fly/pool-caps.conf` | repo file | A reviewed hard cap per project. | no lines | unchanged | none |
| `POOL_CAP_MAX` | `env/global.env` or env | Trims every project at once, unlimited included. | not set: no brake | unchanged. Do not set it. It is the one knob that caps every project. | none |
| `POOL_AUTOSCALE` | env | 0 makes the pool follow the explicit cap only. | not set: 1 | unchanged | none |
| `POOL_SPAWN` | env | 0 stops all spawns. | not set: 1 | unchanged | none |
| `POOL_SPAWN_CAP_PER_KEY` (row `lane.fly-pool.<p>.pool_spawn_cap_per_key`) | settings row, fleet row `pool_spawn_cap_per_key` | One ticket key may buy N machines inside the window. The N+1 spawn waits for the oldest spawn to leave the window. | fleet row `12`; the code default is 2 | row `24` for both (BH-7190 adds the per-project row; before it only the fleet row was read) | worst case 24 machines per key per day: 24 x ~1 h x $0.449 = $10.78 |
| `POOL_SPAWN_CAP_WINDOW_S` | settings row `pool_spawn_cap_window_s` | The window of the cap above. | no row: 86400 | unchanged | none |
| `JOBS_QUEUE_DEFER_MAX` (rows `lane.fly-pool.jobs_queue_defer_max` and `lane.jobs-watchdog.jobs_queue_defer_max`) | settings rows, two lanes | A build that stands itself down this many times is closed `failed` and goes to `bin/blocked-resolver.sh`, which rebuilds it fresh. It is not a count of queued jobs a tick reads (the BH-7190 ticket text said so; the code does not). A stand-down on a named blocker (`After:`) never counts. | not set: 6 | `12` in both lanes, fleet-wide. The watchdog does not know the project, so a per-project value would make the two lanes disagree. | each stand-down is one more machine start: up to 6 more at $0.449 x the stand-down length |
| `POOL_LANE_FAIL_HOLD_S` | env or lane row | After a runner-lane failure (account out of quota) the whole project spawns nothing for N seconds. | not set: 1800 | unchanged. The hold protects against a spawn loop on a dead lane. | none |
| `POOL_AFTER_MAX_MIN` | lane row | A ticket that waits on a named blocker (`After:`) is released after N minutes. | not set: 360 | unchanged | none |
| `POOL_EXECUTE_EMPTY_MAX` / `_WINDOW_S` | lane row | N empty executions of one key stop the relaunch and place one NEEDS_HUMAN hold. | not set: 2 | unchanged. Two empty runs mean a ticket problem, not a slot problem. | none |
| `POOL_STALL_ALERT_S` (BH-7107) | lane row | Not a hold. Pages once an hour when work is queued and nothing builds. | not set: 1800 | unchanged | none |
| `POOL_MACHINE_HOURS_DAILY` (BH-7190) | row `lane.fly-pool.<p>.pool_machine_hours_daily` | Not a hold. Alerts at the percent below and at 100%. | no row | `project-6-os` 300, `cromford` 700 | 300 = $134.79 a day; 700 = $314.52 a day |
| `POOL_BUDGET_ALERT_PCT` (BH-7190) | row `lane.fly-pool.pool_budget_alert_pct` | The first alert of a UTC day. | no row: 80 | `80` | none |

### Knobs that do not hold a pool build

These are real caps, but not on the pool route (`docs/BUILD-CONCURRENCY.md`).
A project routed `pool` ignores them.

| Knob | Where | Now |
|---|---|---|
| `fleet.conf` | repo registry | Has no slot column. It names the project, repo, URL, board prefix, cron offset, box and tailnet IP. It holds no cap. |
| `concurrency_rules` `repo/<p>/build` | coordination DB (`bin/jobs-client.sh rules`) | No row for either project. Only `ticket/*/*` and `ticket/*/build` = 1 exist (one claim per ticket). |
| `BUILD_SLOTS` | `env/global.env` on the project box | not set: unlimited. Never taken on a pool machine. |
| `flags/wip-limit-<p>` | the project box | no file for either project |
| `FLY_DISPATCH_WIP` | `bin/lib/build-caps.sh` | single-machine route only |
| Account lease cap | `fly/account-capacity.conf` (claude 4, codex 4) | Ranks accounts so a tick spreads load. It fails open to the shared token. It does not hold a build. |

### Things that hold a build and are not numbers

| Cause | Where | Clears when |
|---|---|---|
| `HOLD` comment or body line on the ticket | GitHub issue | a person removes it |
| An open PR for the key | GitHub | the PR closes |
| `After: <KEY>` wait | queue row | the blocker is done (or `POOL_AFTER_MAX_MIN`) |
| `flags/paused-<p>` | hub | a person removes it |
| `flags/pool-halt-<p>` | hub | the next harness deploy |
| `state/pool/<p>/_spawn-hold` | hub | `POOL_LANE_FAIL_HOLD_S` passes, or `bin/pool-state.sh lift-hold <p>` |
| Orphan slot: a job file whose machine is gone | pool state | `bin/fly-pool.sh` releases it every tick (PR #7169, BH-7107) |
| No Fly token for the project | `env/fly.env` | the tick falls back to the org token (PR #7169, BH-7107) |

## The settings rows this ticket sets

Apply with `bin/pool-never-wait-seed.sh --apply` on the hub. The script is a dry run without `--apply`, and a second run changes nothing.

| Row | Value |
|---|---|
| `lane.fly-pool.project-6-os.pool_cap` | 0 |
| `lane.fly-pool.cromford.pool_cap` | 0 |
| `lane.fly-pool.project-6-os.pool_spawn_cap_per_key` | 24 |
| `lane.fly-pool.cromford.pool_spawn_cap_per_key` | 24 |
| `lane.fly-pool.project-6-os.pool_machine_hours_daily` | 300 |
| `lane.fly-pool.cromford.pool_machine_hours_daily` | 700 |
| `lane.fly-pool.pool_budget_alert_pct` | 80 |
| `lane.fly-pool.jobs_queue_defer_max` | 12 |
| `lane.jobs-watchdog.jobs_queue_defer_max` | 12 |

How the two budgets were chosen (machine rows on the hub, 2026-10-12 to 2026-10-16):

| Project | Busiest recent day | Budget | Alert at 80% |
|---|---|---|---|
| `project-6-os` | 164 machine-hours (2026-10-15) | 300 | 240 machine-hours |
| `cromford` | 638 machine-hours (2026-10-14, partly orphan slots); 227 on 2026-10-15 | 700 | 560 machine-hours |

Change a budget with the console or `bin/jobs-client.sh setting-set <row> <value>`. Delete the row to remove the budget.

## The budget guard

`bin/pool-budget.sh` runs at the end of every `bin/fly-pool-tick.sh`.

1. It reads the project's budget row. No row, no check.
2. It lists the project's machine rows and adds the time each machine ran inside the current UTC day.
3. It writes one log line per project per tick to `logs/fly-pool.log`.
4. At the alert percent it writes one `warn` alert per project per day (`--id pool-budget-warn-<p>`). At 100% it writes one more (`--id pool-budget-limit-<p>`).
5. It changes nothing else. A settings or listing outage is logged, not alerted.

A live machine with no `spawned_at` cannot be timed. The log line counts these rows ("not counted"). The listing holds the 500 newest rows, so a project with 500 rows inside today is marked "listing full".
