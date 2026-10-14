# BH-2343 (BH-2316.0): brake ledger helper and alert_families state filter

Doc: DB-COORDINATION-SPEC

## What changed

- New sourced library `bin/lib/brake-ledger.sh`. It sits on the existing `ledgers(kind,key)`
  table through `job_ledger_put` and `ledger_page`. There is no schema change, no migration and
  no worker deploy.
  - `brake_db_on` is `alerts_db_on` (`flags/alerts-db`). It adds no new flag, and it is rc 1 when
    `bin/lib/alert-state.sh` is not loaded.
  - `brake_mark <name> <key> <epoch> [detail_json]` writes status `set` with detail
    `detail_json + {"at":epoch}`, and `at` always wins.
  - `brake_clear <name> <key>` writes status `cleared`.
  - `brake_read <name> <max_age_s>` prints `key<TAB>epoch<TAB>detail_json` for the `set` rows
    with `at >= now - max_age_s`. `at` is `detail.at`, or `updated_at` when the row has none.
- `alert_families <lane> <claimed_since_s> [state]`: a third arg appends `&state=<state>`. A
  2-arg call sends the same URL as before.

## Kinds

`brake:triage-family`, `brake:triage-deferred`, `brake:triage-cliff`, `brake:medic-family`,
`brake:medic-parked`, `brake:medic-seen`, `brake:responder-handled`. A name must be
`[a-z0-9-]+` and at most 26 chars. The worker slices `kind` to 32, so a longer name would be
written under one kind and read under another. Such a name is refused with rc 1 and no request.

## Failure semantics

- mark and clear return the `_jobs_req` rc verbatim. The lane's local file stays primary, and the
  lane writes the file first.
- On a read outage, `brake_read` returns rc 1 and prints NO rows. An outage is a transport
  failure, a 200 that is not JSON, or a body with no `.ledgers` array. The rule holds even when
  earlier pages were fine, because rows are buffered until the whole walk succeeds. rc 0 with
  no rows means there really are no brakes.
- The read walks `before=<last updated_at>` 1000 rows at a time. It stops when a page is short
  or when that page's oldest row is older than the window. After 5 pages it stops and prints
  `#truncated` as the last line.

## Who calls it

Nothing yet. Slices 2 to 4 of #2316 wire it into alert-triage, alerts-medic and
watchdog-responder.
