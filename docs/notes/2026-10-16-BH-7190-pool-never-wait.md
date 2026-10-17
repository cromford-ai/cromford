# The pool never waits on a number we chose, and a machine-hour budget bounds the spend (BH-7190)

Doc: FLY-POOL, BUILD-CONCURRENCY

## Why

On 2026-10-16 project-6-os showed 7 orphan jobs and 11 tickets that waited 382 minutes, while `POOL_CAP_MAX` was already unset. No single page listed the knobs that can hold a pool build, so nobody could say which one bound. The orphan release is BH-7107 (PR #7169). This note covers the rest.

## What changed

1. **`docs/FLY-POOL.md`** lists every knob that can hold a build, with the value read on the hub, the "never wait" value and the cost per machine-hour ($0.449 for `performance-8x`, 16 GB).
2. **Per-project spawn cap.** `pool_spawn_cap_load` in `bin/fly-pool.sh` reads `lane.fly-pool.<project>.pool_spawn_cap_per_key` first, then the fleet row `pool_spawn_cap_per_key`, then the env, then 2. Before this, a per-project value was inert because the fleet row always won.
3. **`bin/pool-never-wait-seed.sh`** writes the nine rows (dry run by default, idempotent). `project-6-os` and `cromford` get `pool_cap` 0, `pool_spawn_cap_per_key` 24 and a daily budget (300 and 700 machine-hours).
4. **`bin/pool-budget.sh`**, run at the end of `bin/fly-pool-tick.sh`, adds the project's machine running time for the UTC day. It writes one alert at `pool_budget_alert_pct` (80) and one at 100%. It stops nothing and changes no cap.
5. **Catalog notes.** `JOBS_QUEUE_DEFER_MAX` is the number of stand-downs before a row parks for the blocked-resolver. It is not a count of jobs a tick reads, as the ticket text said. Two new knob files register the budget rows.

## Why defer-max is fleet-wide

`bin/jobs-watchdog.sh` reads its own copy of `JOBS_QUEUE_DEFER_MAX` and does not know the project. A per-project value in the pool lane would disagree with the watchdog. Both lanes get `12` as a fleet row.

## Not done here

The orphan release is PR #7169 (BH-7107).
