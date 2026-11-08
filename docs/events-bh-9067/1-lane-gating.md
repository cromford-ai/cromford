# Lane gating
<!-- owner: BH-9067.1; this file is empty on purpose so siblings never share lines -->

BH-9073 (BH-9067.1). This file lists the model lanes behind the lane wake gate
(`bin/lib/lane-wake-gate.sh`, contract BH-9072), the lanes that stay exempt and
why, the backstop rule, the flip steps, and the run-triage empty-tick stop.

## The gated lanes

A scheduled tick of a gated lane calls `lwg_take <lane> <scope>` inside
`lane_gate_or_exit`. Each lane has one registry file
`catalog/lane-wakes.d/<lane>.json`, one mode knob
`catalog/lanes.d/_lib.lane-wake-gate.knobs.d/MODE_<LANE>.json` (default
`shadow`) and one backstop ring file `catalog/lane-calendar.d/<lane>.tsv`.

| lane | scope | kinds (webhook rows that wake it) | backstop ring | cron today |
|---|---|---|---|---|
| run-triage | project | issue, push | `7 * * * *` | every 10 min per project |
| review-prs | project | pr, checks | `13 * * * *` | */30 |
| merge-queue | project | pr, checks, push, merge_group | `19 * * * *` | */20 |
| postmerge-qa | project | deploy, push | `27 * * * *` | 2-4 per hour |
| run-product | project | issue | `0 9 * * 1` | weekly Mon 09:0x |
| alert-triage | fleet | none (rings only) | `3 * * * *` | */10 |
| alerts-medic | fleet | none | `18 * * * *` | 18,48 |
| archie-cards | fleet | none | `2 * * * *` | 2-52/10 |
| component-watch | fleet | none | `15 * * * *` | */15 |
| daily-digest | fleet | none | `0 * * * *` | */15 |
| dequeue-watch | fleet | none | `5 * * * *` | */5 |
| review-rescue | fleet | none | `37 * * * *` | 7,37 |
| sentry-triage | fleet | none | `11 * * * *` | 11,41 |
| staff | fleet | none | `30 * * * *` | */15 |
| unblock | fleet | none | `4 * * * *` | 4-59/10 |
| watchdog-responder | fleet | none | `23 * * * *` | 3,23,43 |

The scope is `project` when the lane's script passes a project to
`lane_gate_or_exit`, else `fleet`. A `fleet` take reads rings only.

## Exempt lanes

`catalog/lane-wakes.d/_exempt.tsv` names every other census model lane
(`catalog/llm-sites.d`) that has a cron cadence, with a class and a reason:

| class | lanes | why |
|---|---|---|
| owned | pm-groom, claude-auth-check, archie, archie-research, archie-fm-watch, rule-miner, lookback, orc-monitor, fly-pool | a sibling ticket gates them (BH-9072, BH-9074) |
| backstop | merge-conductor, blocked-resolver | behind `bin/lib/cadence-backstop.sh`, launched by `bin/wake-loop.sh` |
| schedule | healthcheck, apply-migrations, deploy-train, archie-learn, lesson-propose, prompt-eval, lesson-classify, review-autopilot | a clock is the job, or a backstop ring equals the cron |
| box | lead-review, preplan-tick | box-scoped; one fleet ring is taken by one box only |
| on-demand | box-chat, feature-map-draft, greenfield, prebuild-repro, security-audit, trap-eval, web-task | no cron line |

`tests/lane-wake-map.bh-9073-test.sh` (M1) fails when a census lane with a
cron cadence has neither a registry file nor an exempt line.

## Backstop

The cron line of a gated lane does not change: its tick is the wake-poll
period. The backstop is a calendar ring. `bin/lane-wake-calendar.sh` (BH-9074)
reads `catalog/lane-calendar.d/<lane>.tsv` (`<5-field cron expr>\t<date key
format>`) and calls `lwg_ring <lane> <scope> cal:<key>` for each lane whose mode
is not off. The next tick takes that ring and runs (`run wake=<id>`). Each
hourly-or-faster lane rings once an hour. run-product rings Monday 09:00.

`bin/lib/cadence-backstop.sh` is not used for these lanes: it is a skip gate,
so in front of a wake-gated lane it can only delay a wake.

## Flip steps

Each lane ships in `shadow`: the take runs, `logs/lane-wake-gate.log` gets
`lwg <lane> <scope> would-skip` when `on` would skip, and the lane always runs.

1. Read the shadow lines of the lane for at least one day.
2. Set the settings row `lib.lane-wake-gate.mode_<lane, - as _>` to `on`
   (example: `lib.lane-wake-gate.mode_run_triage`). Write it as an operator
   settings write (`PUT /api/settings`, the Mission Control settings page).
   `bin/harness-ctl.sh set` takes lane ids only, so it cannot write this
   `lib.` row.
3. To stop one lane, set its row to `off`. To stop every gated lane, set the
   row `lib.lane-wake-gate.mode_default` = `off`.

Do not flip a `fleet` lane to `on` before `bin/lane-wake-calendar.sh` runs on
the hub. A fleet take reads rings only, so with no ringer the lane never runs.

## run-triage empty-tick stop

`ts_tick` (`bin/lib/triage-state.sh`) calls `_ts_wake_idle_end` after the
pre-check. With `lib.lane-wake-gate.mode_run_triage` = `on`, it ends the tick at
$0 (no session) when all of these hold: the pre-check ran on readable rows
(`TS_READY=1`); the gate reason is not forced, forced-env, daily-sweep,
remote-results-pending, no-gate-state or gate-fetch-failed; the tick has 0
`llm` rows (new, changed, recheck-due and every other reason); no enqueue
candidate, queue line, finished build or remote result; and no UNBLOCKED,
STACKABLE, `board prs:` or REOFFER line. The lane log line is
`rc=skip :: triage-state: wake gate on, new=0 chg=0 due=0 — no session [gate=<reason>]`.
In `shadow` the same test writes
`triage-state <project>: wake gate shadow, new=0 chg=0 due=0 — would end at $0, the session runs [gate=<reason>]`
to `logs/lane-wake-gate.log` (the file of every `would-skip` line), and the
session runs. The project log of a shadow tick does not change. In `off`
nothing changes.
