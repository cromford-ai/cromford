# The staff agent contract: levels, seen-count, lever actions, metric samples (BH-9187, slice C0)

Doc: DB-COORDINATION-SPEC

## Why

BH-9187 makes every staff agent own ONE metric and judges it by whether the
metric moved. The ticket has four workstreams: the contract, three pilot
agents, the report and screens, and four second-wave agents. This slice (C0)
ships only the contract. The pilots, the report and the second wave are child
tickets that call what this note lists.

## What changed

### Settings rows (schema.d/202611100721-bh-9187-staff-contract.sql)

One set per roster agent (archivist, clerk, dispatcher, inspector, millwright,
quartermaster, watchman):

| Key | Seed | Meaning |
|---|---|---|
| `staff.<agent>.level` | `observe` | `observe` (digest only), `file` (may file tickets), `act` (may file tickets; its listed levers come in its child slice) |
| `staff.<agent>.metric` | per agent | the one metric the agent owns |
| `staff.<agent>.target` | per agent | the target for that metric |
| `staff.<agent>.file_max_day` | `3` | filings per UTC day at level file or act |

Metrics and targets: inspector `hours_behind_main` 2, clerk `needs_count` 300,
dispatcher `ready_unqueued_2h` 0, watchman `live_unrotated_secrets` 0,
quartermaster `orphan_usd_day` 0, millwright `failed_bakes_and_broken_boxes` 0,
archivist `causes_fixed_by_hand_twice` 0. Every one is lower-is-better.

Also: `staff.settle_hours` (24), `staff.scorecard_days` (7, the scorecard
window when no `days=` is given), `staff.scorecard_days_max` (30), `retention.staff_metric_samples.days` (90),
`retention.staff_lever_actions.days` (365),
`retention.staff_finding_seen.orphan_days` (1).

### One row per fingerprint

`POST /api/staff/findings/claim` upserts `staff_finding_seen` on every claim
that resolves to a row (200 claimed or 409 already_claimed). A new claim is
`seen_count` 1, and it resets a seen row that a deleted finding left. A repeat
adds 1 and moves `last_checked_at`. A repeat with no seen row (a finding
claimed before BH-9187) starts at 2, because a 409 proves one earlier claim,
with `first_seen_at` = the finding's `claimed_at`. No backfill is needed. The
row agent is the finding owner. The answer carries `seen_count`, `first_seen_at` and
`last_checked_at`. A failed upsert leaves the claim answer and adds
`seen: "unrecorded"`. A suppressed or staff-filed claim writes no seen row. A
repeat writes no finding row and no acted file, so it does not count toward
the overlook tripwires.

### The outcome ledger (src/routes/staff-levers.js)

- `POST /api/staff/levers/actions {agent, lever, target, dryRun, metric,
  metricBefore, key, detail?}`: one row per `sha256(agent|lever|key)`. The
  same key and payload is 200 `existing: true`. The same key with another
  target, dryRun, metric or metricBefore is 409 `key_mismatch`. metricBefore
  must be a finite number (400 else). An agent off the roster is 404.
- `POST /api/staff/levers/metric {agent, metric, value, detail?}`: in one
  batch, stores one sample and settles every open, non-dry-run action of that agent and metric
  that is at least `staff.settle_hours` old. `moved = 1` when the sample is
  lower than `metric_before`. A bad or absent settle row uses 24 and the answer
  says `settle_hours_fallback: true`.
- `GET /api/staff/levers/scorecard?agent=<a>[&days=<n>][&metric=<m>]`
  (`days` 1 to `staff.scorecard_days_max`, default `staff.scorecard_days`): the
  metric, target and level rows, `metric_now`, `metric_then` (the latest sample
  at or before now minus days), `actions`, `dry_runs`, `settled`, `moved` and
  `precision` (moved / settled; null when 0 settled). Spend is not in this read.

### The level gate and the day cap (bin/staff.sh, bin/lib/staff-contract.sh)

`staff.sh tick` reads `staff_level <agent>` once per tick, after the roster
row. No row, an outage or a value other than observe, file or act is
`observe`. Before each filing (a new decision or a held retry) the tick checks:

1. the level is `file` or `act`, else one digest line `verdict=level`;
2. the filings today (acted files with outcome `filed` in the UTC day) are
   under `staff.<agent>.file_max_day` (fallback 3), else one digest line
   `verdict=file-cap`.

A gated new decision is recorded `digested` and GitHub is not called.

The held rule (r3). A held filing (GitHub refused it on an earlier tick) that
the gate stops STAYS held. The tick writes no digest line, no acted file and
no other state, and calls no GitHub API. It writes one log line
`held filing <fp12> waits: contract level|file-cap` and counts it in `held=`.
A later tick files it when the level is `file` or `act` and the day cap has
room. Then the held file is removed, as before BH-9187.

The existing
autonomy decision (agent-core `decide`) and the open-issue marker dedupe still
apply. The summary line in `logs/staff.log` carries `contract_level=<l>` (and
`contract_level_fallback=1` when the level is the fallback).

The lib also has `staff_knob`, `staff_filed_today`, `staff_action_post` and
`staff_metric_post` for the child slices.

## What a child slice calls

1. Read the agent's level with `staff_level <agent>`. At `observe`, write no
   lever action.
2. Before a lever runs, read the metric, then `staff_action_post` the action
   with `dryRun: true` until the slice moves the agent to `act`.
3. Each tick, `staff_metric_post` the metric. The worker settles due actions.
4. Read the result from `GET /api/staff/levers/scorecard`.

## Retention

`retention.d/bh-9187-staff-contract.js`, on the hourly `bin/d1-retention.sh`
lane with its dry-run row: samples older than 90 days, SETTLED actions older
than 365 days (an unsettled one is never removed), and seen rows whose finding
is gone.

## Tests

`worker/jobs/test/staff-contract.bh-9187.test.js` (routes, EXPLAIN at 50k/20k
rows, retention) and `tests/staff-contract.bh-9187-test.sh` (the lib, and the
gate through `bin/staff.sh tick` and `bin/archie-overlook.sh`).
