# ACCOUNT & TOKEN HEALTH panel on /settings (BH-2516.3, BH-2647)

Doc: ACCOUNT-ROUTING

## What changed

Mission Control's `/settings` hub tab has a new section below PROJECT
ACCOUNTS: ACCOUNT & TOKEN HEALTH. It reads
`GET /api/coord/account-leases/health`. The coord proxy forwards that GET to
the jobs worker's `GET /api/account-leases/health`, so no proxy or worker
change was needed. It refreshes every 60 s while the page is open.

- One row per credential (Claude OAuth, GitHub App): kind, account, live
  lease count, expiry (`in 3h 10m`, `expired 20m ago`, `—` when unknown),
  last refresh age, fail count, last error and box.
- A row is red (with `EXPIRING` in its EXPIRES cell) exactly when the worker
  says `expiring`. The console does no clock math, and the threshold lives in
  the worker (`warn_h`, from the `lib.token-health.token_health_warn_h`
  settings row or its default). The note under the table names the threshold
  and whether it came from settings or the default.
- Clicking an account opens a table of its live leases: machine, box, project
  (linking `/p/<project>`), ticket and lease expiry.
- A failed read shows the error with RETRY. It is never shown as "no
  accounts". `no accounts reported` means the read worked and returned zero
  rows.

It is read-only. There is no form, no confirm and nothing to write.

## Current state

Only the contract (#2644) is merged, so the worker route is still the stub
and answers zero accounts. The panel shows `no accounts reported` in
production until the reporting siblings (#2645, #2646) fill it. The populated
table is covered by fixture tests only
(`console-ui/tests/token-health.bh-2647.test.js`).
