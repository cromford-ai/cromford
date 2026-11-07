# Wake pollers (BH-9074, BH-9067.2)

This file is the content of the seam `docs/events-bh-9067/2-wake-pollers.md`.
The contract PR (#9122, BH-9072) creates that seam as a stub. This content is
in its own file so the two PRs do not conflict. After #9122 merges, the stub
gets one link line to this file.

Three hub lanes. Each one starts work from an event, not from a fixed
schedule. None of them calls a model or a vendor.

| Lane | Script | Cron fragment | Off switch |
|---|---|---|---|
| lane-wake-calendar | `bin/lane-wake-calendar.sh` | `cron/lanes/738-lane-wake-calendar.cron` (`* * * * *`, lease-gated, `flock -n`) | `flags/lane-off-lane-wake-calendar` |
| orc-monitor | `bin/orc-monitor.sh` | `cron/lanes/620-orc-monitor.cron` (`*/5`, lease-gated, behind `cadence-backstop.sh`) | `/root/orchestrator/flags/monitor-off` (read by the hub script), `flags/monitor-off` or row `switch.monitor-off`, `flags/lane-off-orc-monitor` |
| pool-wake-poll | `bin/pool-wake-poll.sh` | `cron/lanes/241-pool-wake-poll.cron` (`* * * * *`, lease-gated, `flock -n`) | `flags/lane-off-pool-wake-poll` |

## 1. The calendar scheduler

A calendar lane is a lane whose ticks have no event behind them: claude-auth-check,
archie, archie-fm-watch, archie-research, rule-miner, lookback, pm-groom and
orc-monitor. With the lane wake gate (#9122) in mode `on`, a tick of such a
lane runs only when it takes a ring. The scheduler writes those rings.

- Input: `catalog/lane-calendar.d/<lane>.tsv`. One line per calendar entry:
  `<5-field cron expr><TAB><key format>`. `#` lines and blank lines are
  ignored. The key format is a `date -u +FORMAT` string. The dedupe is
  `cal:<key>`, lowercased. It must match `^[a-z0-9:#@._-]{1,64}$`.
- Scope: `catalog/lane-wakes.d/<lane>.json` `.scope`. `fleet` rings once.
  `project` rings once per `bin/fleet-conf.sh --projects` entry.
- The cron expression is standard: `*`, `N`, `a-b`, `*/n`, `a-b/n` and
  comma lists. Day of week 0-7 (0 and 7 are Sunday). When day of month and
  day of week are both restricted, either one matching is enough.
  `bin/lane-wake-calendar.sh --match '<expr>' <epoch>` answers rc 0 (match),
  1 (no match) or 2 (malformed).
- Lead: at minute M the scheduler rings for the targets M+1..M+LEAD
  (`LANE_WAKE_CALENDAR_LEAD_MIN`, row
  `lane.lane-wake-calendar.lane_wake_calendar_lead_min`, default 2, range
  0..4). The ring is then in D1 before the lane's own tick takes. The dedupe
  comes from the target minute, so the second attempt is `inserted=0`. LEAD 0
  rings the matching minute itself.
- The rings of one tick run in parallel (one background job each).
- A lane in mode `off` is not rung. A lane with no `catalog/lane-wakes.d`
  file is skipped with one line, and only in a minute that matched.

The backstop period of each calendar lane is its current cron line. This PR
changes no lane cadence and no lane cron line. A ring only lets a tick
through; it does not start one (`bin/wake-loop.sh` drops `harness/lanes`
rows). So a longer cron period would lose runs, and the cron shrink belongs
after the gate is `on` (#9073).

Log lines (`logs/lane-wake-calendar.log`):

```
lane-wake-calendar ring <lane> <scope> <dedupe> inserted=<0|1>
lane-wake-calendar ring-failed <lane> <scope> <dedupe>
lane-wake-calendar skip <lane> (no catalog/lane-wakes.d/<lane>.json)
lane-wake-calendar bad-expr <lane> <expr>
lane-wake-calendar bad-key <lane> <fmt>
lane-wake-calendar off (no lane wake gate lib)      (minute 00 only)
```

A ring that fails while the lane is in mode `on` writes one ALERTS line per
lane per day.

## 2. orc-monitor in the repo

`bin/orc-monitor.sh` is the gate in front of the hub's monitor
`/root/orchestrator/bin/orc-monitor.sh`. The build box could not read the hub
script, so this PR does not copy it. The orchestrator's kill,
`/root/orchestrator/flags/monitor-off`, stays with the hub script: the cron
line ran that script directly before this wrapper, with that file as its
documented kill, so the wrapper does not read it again. The wrapper does, in
this order:

1. `lane_gate_or_exit orc-monitor` (the lane switch, pause rows and, with
   #9122, the wake gate for `catalog/lane-wakes.d/orc-monitor.json`, scope
   `fleet`).
2. `lane_env_apply orc-monitor`.
3. Exit 0 when `lane_switch monitor-off file` is on (`flags/monitor-off` or
   the row `switch.monitor-off`, the switch `bin/lane-alert.sh` reads).
4. `exec` the hub script with the same arguments.

A missing hub script is one line per hour and exit 0. A hub path that
resolves to the wrapper itself is refused.

The `*/5` line runs behind `bin/lib/cadence-backstop.sh orc-monitor`. Its row
is `lib.cadence-backstop.cadence_backstop_min_orc_monitor`, default 0 (every
tick runs, as before). Set it to 30 when calendar rings wake the monitor
(`catalog/lane-calendar.d/orc-monitor.tsv`, `*/5`).

## 3. The pool dispatcher on queue depth

`bin/pool-wake-poll.sh` reads
`GET /api/wakes?repo=harness%2Fbuild-queue&since=<cursor>&limit=<LIMIT>` every
`POOL_WAKE_POLL_S` seconds for one window. A new queue row starts
`bin/fly-dispatch.sh` and `bin/fly-pool-tick.sh` detached, and then the cursor
moves. So a queued build starts in about 10 s, not at the next `*/10` tick.
`cron/lanes/190-fly-dispatch.cron` and `cron/lanes/240-fly-pool-tick.cron`
stay as the backstop.

| Knob | Row | Default | Range |
|---|---|---|---|
| `POOL_WAKE_POLL_S` | `lane.pool-wake-poll.pool_wake_poll_s` | 10 | 1..60 |
| `POOL_WAKE_POLL_WINDOW_S` | `lane.pool-wake-poll.pool_wake_poll_window_s` | 55 | 1..58 |
| `POOL_WAKE_POLL_LIMIT` | `lane.pool-wake-poll.pool_wake_poll_limit` | 100 | 1..500 |

A value outside its range is one log line and the default.

- Cursor: `state/pool-wake-poll/cursor`, one integer (temp file, then `mv`).
  It moves to the largest id an answer returned. A row of another repo moves
  it and never launches.
- Seed: with no cursor (or junk in it) the run pages from id 0 to the end,
  launches nothing and logs `seeded cursor=<id> pages=<n>`. If the window
  ends first, `cursor.seed` keeps the progress for the next run.
- Order: launch first, cursor second. A launch that cannot start (a fly
  script that is not executable) logs `launch-failed` and leaves the cursor,
  so the next poll tries again. A crash between the launch and the cursor
  write repeats one launch, which the fly lanes' own locks absorb.
- The launches run as scheduled ticks of their lanes (`LANE_SINGLE_RUN=1`),
  so the single-run guard keeps one run per lane.

Log lines (`logs/pool-wake-poll.log`):

```
pool-wake-poll launched wake=<first id> rows=<n>
pool-wake-poll launch-failed wake=<id> (<name> not executable)
pool-wake-poll read-failed (<why>)
pool-wake-poll seeded cursor=<id> pages=<n>
```

## Turning the wake gate on, per lane

Every calendar lane starts in mode `off` (the contract's `MODE_DEFAULT`), so
nothing changes at deploy. To move one lane, set the settings row
`lib.lane-wake-gate.mode_<lane, - as _>` (pm-groom: `mode_pm_groom`):

1. Set it to `shadow`. The lane still runs every tick, and
   `logs/lane-wake-gate.log` shows `run wake=<id>` or `would-skip`.
2. Check that every tick that should run has `run wake=<id>`.
3. Set it to `on`. A tick with no ring now exits 0 before any work.

Do NOT set claude-auth-check to `on`. That lane checks the credential of
every box, and a `fleet` ring is taken by one box only. Mode `on` would leave
every other box unchecked. `shadow` is safe.

## D1 cost

- pool-wake-poll: one GET per `POOL_WAKE_POLL_S` on the hub, about 8,640 a
  day at 10 s. Each one is an index seek on `idx_wakes_repo_id(repo, id)`
  that returns 0 or 1 rows in the steady state.
- lane-wake-calendar: 0 statements in a minute that matches nothing. With
  every mode on, about 540 `INSERT OR IGNORE` a day. With every mode off, 0.
- orc-monitor: no new statement (the wake gate's take is the contract's).

Tests: `tests/lane-wake-calendar.bh-9074-test.sh`,
`tests/orc-monitor.bh-9074-test.sh`, `tests/pool-wake-poll.bh-9074-test.sh`.
