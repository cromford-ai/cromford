# Ledger archive read fallback (BH-6863, slice C0 of BH-6780)

Doc: OPERATING

## What changed

- `GET /api/ledger?kind=<k>&key=<key>` reads the hot `ledgers` table first, as
  before. On a hot miss, if `<k>` is listed in `retention.ledgers.archive_kinds`
  or `retention.ledgers.archived_kinds`, it does one point read on `env.ARCHIVE`
  (`worker/jobs/src/lib/ledger-archive.js`).

| Case | Answer |
|---|---|
| hot hit | 200 `{ ledger }`, as before; no settings read, no archive read |
| kind in neither list | 404 `{ error: "not found" }`; `env.ARCHIVE` is not touched |
| listed, archive row found | 200 `{ ledger, archived: true }` |
| listed, row absent, or the archive has no `ledgers` table | 404 `{ error: "not found" }` |
| listed, archive read throws any other error | 503 `ledger archive unavailable` |
| in `archived_kinds`, `env.ARCHIVE` not bound | 503 `archive not bound` |
| in `archive_kinds` only, `env.ARCHIVE` not bound | 404 |
| the settings read throws | 503 `settings unavailable` (before this change: 404) |

- A list is a comma list. Each entry is trimmed. Empty entries, entries longer
  than 32 characters and entries after the 64th are dropped.
- `POST /api/ledger/claim` calls `claimArchiveGuard` (`worker/jobs/src/lib/ledger-archive-claim.js`)
  after its input checks and before the INSERT. It returns null, so the claim is
  unchanged. BH-6780.1 owns it.
- `worker/jobs/schema.d/202610151000-bh-6780-ledger-archive.sql` seeds three
  settings rows:
  - `retention.ledgers.archive_days` = `0` (off; read by the ledgers.archive rule, a later slice)
  - `retention.ledgers.archive_kinds` = empty
  - `retention.ledgers.archived_kinds` = empty (the archive rule writes it; never remove a kind by hand while its rows are in the archive)

## Defaults in prod

Both lists are empty, so every hot miss answers 404 as before and no request
reads the archive. Nothing moves rows to the archive yet. The `ARCHIVE` binding
comes with #6777.

## Why

`ledgers` is a history table and retention never deletes it (BH-6750). Old rows
of some kinds move to a second store. A reader that asks for one of those keys
must still find it.
