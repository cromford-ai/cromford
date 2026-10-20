# Tackler metrics, override detection, console page, weekly report (BH-7728, UNB-6)

Doc: EVENTS, OPERATOR-SETUP

## What changed

- A new worker route family `unblock-metrics`
  (`worker/jobs/src/routes/unblock-metrics.js`, fragment
  `worker/jobs/test/route-table.d/bh-7728-unblock-metrics.txt`):
  `GET /api/unblock/metrics`, `GET /api/unblock/metrics/decisions`,
  `GET /api/unblock/overrides/candidates`, `POST /api/unblock/overrides`.
  The definitions of the four metrics are in the module header.
- A new hub lane `unblock-metrics` (`bin/unblock-metrics.sh`, registry
  `catalog/lanes.d/unblock-metrics.json`, cron
  `cron/lanes/418-unblock-metrics.cron`, hourly at :17 behind
  `hub-lease.sh check`). No model call. Each tick runs the override pass
  (`bin/lib/unblock/override.sh`), writes one metrics line per active project
  once per UTC day to `logs/unblock-metrics.log`, and calls
  `bin/staff/tackler-report.sh run`, which sends the weekly precision report
  through Archie's beat gate on `TACKLER_REPORT_DOW` (Monday).
- A new console screen `/unblock` (headline TACKLER, under the STAFF tab):
  four tiles, the 7-day trend and the ledger list.

## Why

The spec (`docs/plan/PR_UNBLOCK_AGENT_PLAN_2026-10-20.html`, PR #7721) slice
S6: the four metrics on the console, daily, with a 7-day trend; one override by
a person inside 24 h demotes the class to `ask_first`; the weekly report
carries precision per class and any promotion.

## What it depends on

- The table `unblock_decisions` is UNB-0's (#7722). This change ships no
  schema. Until UNB-0's fragment is applied, every route answers 503
  `unblock_decisions schema not applied`, the override pass writes one
  `ledger not live` line, and the console shows "Tackler ledger is not live
  yet".
- A class is the `class` field of `catalog/unblock-rules.d/<rule_id>.json`
  (UNB-1..3). A row whose rule file or field is missing is stamped with
  `demote: no-class` and nothing is demoted.
- In shadow mode Tackler makes no `done` act, so the override pass finds 0
  candidates until UNB-4's flip. The `would` count per day shows the shadow
  period.

## Off

`UNBLOCK_METRICS_ENABLED=0`, `flags/lane-off-unblock-metrics`,
`flags/staff-off-tackler`, or `bin/harness-ctl.sh off unblock-metrics`.
The settings row `unblock.metrics_days` (1..30, absent = 7) sets the default
window of `GET /api/unblock/metrics`.
