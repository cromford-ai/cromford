# The ledger list pages on `(updated_at, key)`, not on a timestamp alone

Doc: DB-COORDINATION-SPEC

## What was wrong

`GET /api/ledger?kind=…&before=…` paged with a strict `updated_at < before`, and `ORDER BY updated_at DESC` had no tiebreak. `updated_at` has 1-second resolution, so a burst of PUTs lands many rows on one stamp. When a page boundary fell inside a second, every row sharing that second with the page's last row was skipped. 2,500 same-second rows at `limit=1000` came back as one page of 1000, then an empty page. For the alert brakes (BH-2343) a skipped row reads as "not braked", so the paid lane runs again, and a rebuilt hub re-triages it.

## What it does now

- `worker/jobs/src/routes/ledger.js`: the list takes an optional `before_key`. With `before` and `before_key` the predicate is `(updated_at < before OR (updated_at = before AND key < before_key))`. The order is always `updated_at DESC, key DESC`, which matches the predicate. `(kind, key)` is the primary key, so the cursor is unique.
- `before` alone keeps the legacy strict predicate, so a caller that has not moved gets the same rows as before, now in a deterministic order.
- `before_key` without `before` is a `400 {"error":"before_key requires before"}`. A `before_key` over 512 characters (PUT slices keys to 512) is a `400`.
- `ledger_page <kind> <limit> [before] [before_key]` in `bin/lib/jobs/jobs.sh` adds `&before_key=` only when the 4th arg is set. 3-arg calls send the same request as before.
- `brake_read` in `bin/lib/brake-ledger.sh` passes the last row's key along with its `updated_at`. The key is read raw with `jq -r`, not from the `@tsv` header line, because `@tsv` escapes tabs and backslashes. A full page whose last row has no key returns rc 1, like any other response that is not a ledger list.

## What still uses the legacy cursor

The pr_state rehydrate in `bin/lib/mc/settle.sh` still calls `ledger_page` with 3 args. Its own comment already accepts the loss as a row the next transition rewrites. Moving it is a 4th arg on that call.

## Tests

- `worker/jobs/test/routes/ledger-cursor.bh-2450.test.js`: real SQLite, through `worker.fetch`. It covers 2,500 same-second rows, ties at both page edges, the legacy `before`, the order, and the 400s.
- `tests/brake-ledger-cursor.bh-2450-test.sh`: the `ledger_page` request lines, and `brake_read` passing a raw key that contains a tab.
