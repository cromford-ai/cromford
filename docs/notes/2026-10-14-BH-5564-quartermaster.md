# Quartermaster: the cost lanes and two cost checks (BH-5564, wave 7 of #5556)

Doc: EVENTS, COST

## What changed

1. Quartermaster owns the seven cost lanes. Schema fragment
   `worker/jobs/schema.d/202610141706-bh-5564-quartermaster-lanes.sql` adds one
   `staff_lanes` row per lane (`INSERT OR IGNORE`, no DDL). The roster route and
   the `/staff` screen show them. No lane changes: each one keeps its script,
   cron line, kill switch and alerts.
2. A new collector, `bin/staff/quartermaster-collect.sh`. `bin/staff.sh tick
   quartermaster` runs it at step 6. Until now that step found no collector and
   collected 0 items. The collector reads the last `QM_WINDOW_H` hours of D1
   `cost_rows` one time through `cost_rows_fetch`. It makes no model call and
   no gh call. It prints two checks as staff findings:
   - `cost-multiplier`: per (project, stage, runner), paid calls divided by
     distinct inputs. The input is `guard_fp`, the pre-call guard's input
     fingerprint. A row without a `guard_fp` has no known input and is left
     out. A finding when calls >= `QM_MULT_MIN_CALLS` (100) and the ratio >=
     `QM_MULT_MAX` (10). The project-4 shape (2,127 calls, 22 inputs) reads 96.7x.
   - `cost-parity`: per (stage, runner), metered calls with rc 0 and a blank
     `cost_usd`. Metered = a runner in `QM_METERED_RUNNERS` (grok openrouter
     fireworks xai) or `billing_mode=metered`. A finding when the count >=
     `QM_PARITY_MIN_CALLS` (3). `0` is a value, not a blank.
   A `row_source=refused` row is never a call. The item is the check, its keys
   and the UTC day, with no count. So one key gives at most one finding per
   day, and the numbers ride in the title.
3. A read cache, `state/staff/quartermaster/last.jsonl`. A tick inside
   `QM_READ_EVERY_S` (3600 s) prints the last good output again and reads
   nothing. The staff lane ticks every 15 minutes, so the 24 h cost_rows walk
   runs at most once an hour.
4. Knobs are settings rows, `lib.staff-quartermaster.<env>`
   (`catalog/lanes.d/_lib.staff-quartermaster.json`), applied with
   `lib_env_apply staff-quartermaster`. A value out of range is one warn line in
   `logs/staff.log` and the default.
5. The soul's REPORT list names both checks.

Failure: an unreadable `cost_rows` read is rc 1 with no output. staff.sh logs
`collector rc=1; nothing claimed`, and the cache is left as it was. It is never
read as "no findings".

## The lane read

Each lane was read before the ownership row was written. Cadence and switch
are from `catalog/lanes.d/<id>.json`.

| Lane | Measures | Source | Cadence | Switch | Writes |
|---|---|---|---|---|---|
| `cost-reconcile` | Anthropic meter movement against `cost_rows` sums per account; blank-cost rows per runner per hour; OpenRouter bill against openrouter rows | `/api/metrics/extra-usage`, `/api/metrics/cost-rows`, `/api/jobs`, `catalog/cost-accounts.json` | `50 * * * *`, `50 4 * * *` | `lane-off-cost-reconcile` | `/api/metrics/reconcile`, `logs/cost-reconcile.log`, alerts |
| `vendor-spend-pull` | non-Anthropic spend: openrouter from the vendor, xai, fireworks, codex and fly computed | vendor APIs, local `logs/cost.csv` fallback | `33 * * * *` | `lane-off-vendor-spend-pull` | `vendor_spend`, `logs/vendor-spend.csv`, alerts |
| `cost-local-brake` | the cost breaker per project during a harness-jobs outage | local `logs/cost.csv`, GitHub merged PRs | `3,13,23,33,43,53 * * * *` (box) | `lane-off-cost-local-brake` | `flags/spend-hold-<p>`, `logs/cost-local-brake.log`, ALERTS |
| `cap-loss-detector` | time lost to claude cap failovers yesterday | `cost_rows` via `cost_rows_fetch` | `20 6 * * *` | `lane-off-cap-loss-detector` | `logs/cap-loss.log`, a fleet_alert beat |
| `ci-minutes-watch` | billed CI job-minutes over 24 h on MonkCI runners | GitHub `actions/runs` and jobs | `23 */6 * * *` | `lane-off-ci-minutes-watch` | `logs/ci-minutes-watch.log`, `state/ci-minutes/latest.json`, a page |
| `extra-usage-track` | the Anthropic OAuth usage meter per account | `api.anthropic.com/api/oauth/usage`, `/api/metrics/account-usage` | `13,28,43,58 * * * *` (box) | `lane-off-extra-usage-track` | `extra_usage_snapshots`, `logs/extra-usage*.csv`, alerts |
| `orchestrator-burn` | the orchestrator's daily token burn in API dollars | orchestrator transcript files | `55 * * * *` | `lane-off-orchestrator-burn` | `logs/orchestrator-burn.csv`, `metric_burn`, ALERTS |

## Overlap with the two checks

- Multiplier: no lane computes paid calls per distinct input. None of the seven
  reads `guard_fp` or `call_guard`. The call guard (`bin/lib/call-guard.sh`)
  refuses a call over its ceiling per input, but only for the stages it lists.
  This check sees every stage after the fact.
- Parity: `cost-reconcile` already counts blank-cost rows
  (`bin/cost-reconcile.sh`, "the blank-cost flood", BH-1020). It counts rc-0
  rows with an empty `cost_usd` per runner in the last hour, for every runner,
  and alerts over `RECONCILE_BLANK_ROWS_MAX` (20). The box's own
  `cost_parity_alert` (`bin/lib/cost-row.sh`) pages when a call reports no
  tokens at all. `vendor-spend-pull` counts unpriced xai and fireworks rows in
  its row note and does not alert. The new check covers what those miss: a
  slow leak under 20 an hour, on a metered runner, named by stage, over a day.
  It writes a staff finding, not an alert. At `automation` (the seed level)
  that is one digest line.

## Commands

- One tick by hand on the hub: `bin/staff.sh tick quartermaster`, then
  `tail -3 /root/harness/logs/staff.log /root/harness/logs/staff-digest.log`.
- The collector alone: `bin/staff/quartermaster-collect.sh`.
- Suite: `HARNESS_TEST_SANDBOX=1 bash tests/staff-quartermaster.bh-5564-test.sh`.
