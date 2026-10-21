# The MCP server says why a pool project's queued builds do not spawn: pool_status (BH-7709)

Doc: MCP, LANES

## Why

On 2026-10-20 the project-6-os pool had 126 queued rows and 2 running for
hours. The cause took grep work on the hub: env bundle ssh failures (rc 255),
`max-ticks 4 of 4`, and a 600 s tick budget that decided 26 of 126 rows. No
tool showed these facts in one place.

## What changed

1. **Hub lane `bin/pool-tick-summary.sh`** (`*/2 * * * *`, `# @hub-lanes`,
   behind `hub-lease.sh check`, registry `catalog/lanes.d/pool-tick-summary.json`,
   cron `cron/lanes/772-pool-tick-summary.cron`, log `logs/pool-tick-summary.log`).
   It reads the tail of `logs/fly-pool.log` once (`POOL_TICK_SUMMARY_TAIL_LINES`,
   default 20000) and, in one awk pass, builds one row per pool project
   (`flags/fly-pool-*`, the list `bin/fly-pool-tick.sh` walks). It POSTs the rows
   to `/api/pool/tick-summary` in one request. One log line per run:
   `projects=<n> ticks=<n> decisions=<n> POST rc=<rc> http=<code>`.
   `bin/fly-pool.sh` is not changed.
2. **Worker routes** `worker/jobs/src/routes/pool-tick.js` (fragment
   `worker/jobs/test/route-table.d/bh-7709-pool-tick.txt`) and the table
   `pool_tick_summary` (`worker/jobs/schema.d/202610211310-bh-7709-pool-tick-summary.sql`,
   one row per project, overwritten each run, no retention job needed).
   - `POST /api/pool/tick-summary {rows:[…]}` validates each row and stores only
     the known fields. A bad row is counted in `rejected`.
   - `GET /api/pool/status?project=<p>` (format `pool-status v1`) returns the
     row FLAT: `queued`, `running`, `spawning`, `cap` (null when the header says
     `unlimited`), `hotfix`, `last_tick{…}`, `decisions`, `env_bundle_failures_1h`,
     `respawns`, `respawns_since`, plus `spawn_cap_per_key {value, window_s,
     source}` from the settings rows `lane.fly-pool.<p>.pool_spawn_cap_per_key`,
     `pool_spawn_cap_per_key` (default 2) and `pool_spawn_cap_window_s`
     (default 86400). No row: `{project, version: 1, tick: null, reason: "no
     summary row"}` with no `queued` or `running` key. Two PRIMARY KEY reads,
     in parallel.
3. **MCP tool `pool_status {project}`** in `mcp/tools/pool-status.mjs`
   (read-only, no `confirm`). One GET of `/api/coord/pool/status?project=<p>`.
   It groups the decisions into `skips.{waits_for, hold, spawn_cap, env_bundle,
   quota, not_queued, other}` and `spawned`, each `{count, examples}` with the
   first 5 keys in log order. `status` is `ok`, or `no_summary` with the
   `reason`. `report_age_s` and `stale` (over 600 s) come from the worker clock.

## Two readers of one route

Open PR #7762 (BH-7725, the unblock collector `bin/lib/unblock/collectors/infra.sh`)
reads `GET /api/pool/status?project=<p>` through `_jobs_req`. It reads
`queued`, `running`, `last_tick.{at, stop, cap, knob}` and
`respawns[].{key, count, last_result, last_at}`. This route serves those names
at the top level. `worker/jobs/test/pool-tick.bh-7709.test.js` W9 pins them.

## The stop rule

- `last_tick.window_stop` is how the last tick window ended: `budget`, `age`,
  `code` (a stop line inside the window), else `done`.
- `last_tick.stop` is the newest ATTEMPT line of the project when it comes after
  the last window's end and after the newest header: `max-ticks` (the wrapper
  refused a start; `cap` = its cap, `knob` = `POOL_TICK_MAX_PARALLEL`), `shed`
  (the project's own load-shed line) or `hold` (the runner-lane spawn hold).
  Else `stop` = `window_stop`, `at` = `ended_at`, `knob` = `POOL_TICK_BUDGET_S`
  for budget, `POOL_TICK_MAX_AGE_S` for age, else null.
- The lane never writes `stop: "cap"`. No log line proves a cap stop.
- An attempt line proves that the tick lock of the project was free: the wrapper
  writes `max-ticks` only for a project whose lock is not held, and
  `bin/fly-pool.sh` takes its lock before the shed and hold exits. So an attempt
  line after the newest header ends that tick, even inside the quiet window
  (`POOL_TICK_SUMMARY_QUIET_S`). Without this, a project that waits on
  max-ticks every minute would never look ended.
- While the newest tick is still in progress, an attempt line from before its
  header is not the stop: a tick started after it.

## Log lines read

All are `<YYYY-MM-DD HH:MM:SS>Z [pool/<P>] <text>`.

| fact | line text |
|---|---|
| tick header | `pool <P>: queued=<n> running=<n> spawning=<n> cap=<n\|unlimited>[ hotfix=<n>]` |
| waits_for | `skipping <K>: waits for `, `skipping <K>: After: `, `SIBLING_SERIAL <K> waits for `, `SCHED_WAIT <K> reason=` |
| hold | `skipping <K>: HOLD (` |
| spawn_cap | `skipping <K>: spawn cap reached (` |
| env_bundle | `env bundle FAILED for <K>:` |
| quota | `account <a> ran out on <mid> during <K>` (no decide-phase quota line exists, so it is usually 0) |
| not_queued | `pool <P>: <K> not queued :: ` |
| spawned | `spawned <mid> for <K> (` |
| other | any other `skipping <K>: `, `<K>: the queue row refused this claim`, `<K>: the project lease is lost`, `machine run FAILED for <K>`, `harness sync FAILED to <mid> for <K>`, `<K>: no App token for …`, `<K>: token swap produced an empty bundle …` |
| window stop budget | `tick budget of <n>s spent for <P>:` |
| window stop age | `tick stopped at a row boundary: it has run ` |
| window stop code | `tick stopped at a row boundary: the deployed pool code changed` |
| attempt max-ticks | `max-ticks: <run> of <cap> running — <P> waits` |
| attempt shed | `load-shed p90=<n> max=<n> — no spawns this tick (reap ran)` |
| attempt hold | `spawn hold: the runner lane failed (` |
| respawn result | `reaped <K> from <mid>: <RESULT>` (first word) |

## Respawns

`respawns` lists the keys with 2 or more `spawned … for <K>` lines of the
project dated today (UTC), at most 50 (`respawns_truncated`), count desc then
key. `last_result` is the first word of the newest `reaped <K> from <mid>:` line
in the tail, else null. `respawns_since` is the later of today's 00:00Z and the
first tail line, so a short tail shows as a partial day.

## Knobs

Lane `pool-tick-summary`, settings rows `lane.pool-tick-summary.*`:
`POOL_TICK_SUMMARY_TAIL_LINES` (20000, 1000..200000) and
`POOL_TICK_SUMMARY_QUIET_S` (120, 30..1800). A value out of range writes one
ALERTS line (`--id pool-tick-summary-knob`) and the lane exits 1 with nothing
read.

## Tests

- `tests/pool-tick-summary.bh-7709-test.sh` (L1-L26): the lane on scratch logs.
- `tests/mcp-pool-status.bh-7709-test.sh`: runs `mcp/test/pool-status.test.mjs`
  (P1-P9) and `worker/jobs/test/pool-tick.bh-7709.test.js` (W1-W10, X1: the lane
  on the fixture log, the real worker, the real `pool_status`).
