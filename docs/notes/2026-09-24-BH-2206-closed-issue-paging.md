# Kanban reads the whole issue_state ledger, not just its newest 1000 rows

Doc: SCHEDULER, DB-COORDINATION-SPEC

Follows [BH-938](2026-09-24-BH-938-dead-closed-issues.md), which added the
closed-issue join to the kanban DEAD column.

## What changed

`closedIssueKeys` in `console-ui/functions/api/dash/kanban/pipeline.js` used to
make one `GET /api/ledger?kind=issue_state&limit=1000` call. Once the ledger grew
past 1000 rows, any closure older than the newest 1000 dropped out of the closed
set, and its dead card came back on the board. The only sign was
`dead_closed_complete: false`.

It now walks the ledger a page at a time:

- Page 1 is the same request as before. Each later page adds
  `&before=<updated_at of the previous page's last row>~`.
- The walk stops on a short page (`complete: true`).
- The `~` makes the cursor inclusive. The jobs worker's `nowIso()` writes
  `updated_at` to the second, and `bin/issue-state-ledger.sh` writes many rows in
  the same second, so rows that tie the last row's timestamp often land on the
  next page. A plain `before=B` would skip them. `B` is a prefix of `B~`, and
  SQLite compares TEXT byte by byte, so `updated_at < 'B~'` returns every row up
  to and including `B`. Rows read twice are deduped by key, and each key keeps
  the status from its newest row.
- It reads at most `CLOSED_MAX_PAGES = 10` pages (10 000 rows) per walk. When it
  stops early, the result is `complete: false`, and the board already shows that
  through `dead_closed_complete`. It stops early in three cases: it hits the
  cap, a full page's last row has no `updated_at`, or a full page leaves the
  cursor where it was (1000 or more rows in one second).
- It still fails open. A non-200, a malformed body or a thrown fetch on ANY page
  returns `null`, which hides nothing and isn't cached. Only a finished walk is
  cached, for 60 s per isolate.

The jobs worker route (`worker/jobs/src/routes/ledger.js`) already supported
`before=` and is unchanged.

## Tests

`console-ui/tests/closed-issue-paging.bh-2206.test.js`. Its jobs-worker stub
models the route's `updated_at < before` string compare, so the `~` cursor is
exercised as written.
