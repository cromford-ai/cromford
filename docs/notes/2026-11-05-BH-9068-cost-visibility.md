# Cost visibility and routes: the code half (BH-9068)

Doc: COST, MODEL-ROUTES, ci-durations

## What changed

- **Extra-usage meter down alert.** `stale_alert` in `bin/extra-usage-track.sh`
  fires after `EXTRA_USAGE_STALE_HOURS` with no meter reading. The default is now
  2 h (it was 6 h), read through `xc_knob`; 0 or junk falls back to 2. The knob
  row is in `catalog/lanes.d/extra-usage-track.json`. It fires once per outage:
  the flag is `flags/alerted-extra-usage-stale<suffix>` with no date, written
  only after the alert call returns 0, and removed by the first ok poll.
  Before, the flag was per UTC day, so a dead meter alerted every day.
  `EXTRA_USAGE_NOW_EPOCH` is a test seam for the age only.
- **Account prices.** Each account in `catalog/cost-accounts.json` has
  `usd_per_month` (null = not entered). `bin/cost-prices-push.sh` writes them to
  the settings rows `cost.usd_per_month.<account>`. The worker reads those rows,
  not the catalog.
- **Cash line.** `GET /api/metrics/cost-breakdown` (unfiltered reads only) has a
  `cash` object for the UTC day of `until`: subscriptions (price / days in the
  month, accounts from `registry_box_accounts`), overage (the rise of each
  account's `extra_usage_snapshots` meter over the day) and metered (the day's
  `vendor_spend` usd). A missing input makes its part and `cash_usd` null and is
  named in `unknown`. The COSTS screen shows it as the first line of SPEND
  BREAKDOWN (`CashLine` in `console-ui/src/screens/CostBreakdown.js`).
- **Cash line: what it leaves out by name.** Two inputs are out of scope, not
  missing. Each is listed in `cash.excluded` as `{part, name, why}`, is shown
  after the number as `not counted: ...`, and does not make `cash_usd` null.
  - `why=no-login`: an account with no usd reading today whose polls are
    `status=no-login` in `extra_usage_snapshots` (a setup-token cannot read the
    usage endpoint). Its overage is not in the line. Its subscription is. An
    account with one usd reading, or with only `status=error` polls, is still
    `unknown`.
  - `why=subscription-billed`: a vendor whose `vendor_spend` polls today are
    all `status=no-spend-endpoint` (the hourly codex row: no admin key, no usd).
    It is not metered cash. Its subscription is one more row under
    subscriptions, priced by the settings row `cost.usd_per_month.<vendor>`
    (for codex: `cost.usd_per_month.codex`). With no such row the line reads
    `cash unknown (no price: codex)`. `bin/cost-prices-push.sh` does not write
    this row, because the catalog holds accounts only: set it with a settings
    PUT. A poll with a usd for the same vendor on the same day makes it metered
    cash again. An `error` or `auth-failed` poll with no usd is still `unknown`.
  - If every account is `no-login`, overage is `unknown`
    (`overage:no-readable-account`).
- **Plan routes seed.** `worker/jobs/schema.d/202611111514-bh-9068-plan-routes.sql`
  moves the untouched seed rung 0 of `stage.plan` to the `plan` role's rung 0
  (claude-opus-5-5) and of `stage.preplan` to `triage.light`'s rung 0
  (claude-sonnet-5). It copies from those rows because a stage seed brings no new
  model literal (runner-routes.bh-1766 S4). A role with any
  `model_route_changes` row, or a rung not written by `seed`, does not change.
  The live move to claude-opus-5-5 / claude-sonnet-5-5 is an owner PUT.
- **Orgo.** `bin/orgo-state.sh` reads `GET /workspaces` and flattens
  `workspaces[].desktops[]`, because `GET /computers` answers 405. The PUT body
  to `/api/orgo-computers` does not change.
- **Review rule.** The `money` BLOCK class now includes "a lane whose cost rows
  come out unpriced on a live call" (topic 13 and its iron-law fragment).
- **Artifact retention.** `ci-durations-next` keeps 7 days (was 30). Every
  other `upload-artifact` step was already at 3 or 7.

## Not in this change

The owner steps: the route PUTs, the two full `claude login`s, the prices
(the 6 account prices and the `cost.usd_per_month.codex` settings row), the
hub `ORGO_API_KEY`, the desktop retire, the repo retention setting, the
Fireworks and Codex admin keys, the live pricer proofs and the cumulative-row
query on D1. This box has no env or D1 access. `bin/cost-rows-push.sh` is not
changed, because the deltas-or-totals query has not run.
