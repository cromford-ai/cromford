# The doorbell reads the GitHub App's own webhook and stops asking for a PAT

Doc: EVENTS

## What changed

- `bin/gh-token.sh --app-hook` prints the App's own webhook as
  `<url>\t<events,csv>` from `GET /app/hook/config` and `GET /app` on the App
  JWT (empty url, rc 0 = no webhook; rc 1 = the App could not be asked). A GET,
  so the write kill switches do not apply.
- `bin/doorbell-coverage-check.sh`: a repo whose hooks no token can list is
  `armed (the GitHub App's own webhook …)` when the App webhook points at the
  receiver with events subscribed — asked once per run, only for unreadable
  repos. Otherwise it stays `unreadable`, and the alert names the App-side fix
  (set the App webhook to the receiver + events, or grant `Webhooks: read`)
  instead of "a PAT with admin:repo_hook".

## Why

The fleet authenticates as the `cromford` and `cromford-builders`
Apps. Neither holds the Webhooks (repository_hooks) permission, so no
installation token can list a repo's hooks, and the daily alert for
cromford, cromford-console and project-7 demanded a PAT. Probed live
2026-09-24: both Apps answer `GET /app/hook/config` 404 with `events: []` — the
harness receives NO App-level events today, so these repos stay `unreadable`
until the App is given a webhook (a human step in the App settings, with the
worker's `GITHUB_WEBHOOK_SECRET`).

## Tests

`tests/doorbell-app-hook.pool-doctor-test.sh` (red on main). TEST-CHANGE in
`tests/doorbell-coverage-test.sh` and `tests/doorbell-ringing.bh-1034-test.sh`:
their "alert names admin:repo_hook" assertion now requires the App remedy.
