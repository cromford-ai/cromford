# History readers read the archive store too (BH-6779, slice C0)

Doc: none

## The gap

The retention rules (BH-6750, #6777) move old `cost_rows` and `stage_events`
to the archive D1 (`env.ARCHIVE`). A reader whose window reaches past the move
answers short: an old cost range loses its rows and sums, and an old job loses
its stage events.

## What changed

- `worker/jobs/src/lib/archive-read.js` is the one helper. `readHistory()` runs
  the read on the hot store. It runs the same read on the archive only when the
  range can reach it:
  1. `ARCHIVE` has no `prepare()`: `unbound`, hot only.
  2. `since` is at or after now - 1 day: `not-needed`, 0 archive calls. An
     archive rule never moves a row younger than 1 day.
  3. The archive's newest time (`SELECT MAX(ts)` / `MAX(created_at)`) is
     missing, NULL, or older than `since`: `not-needed`.
  4. Else the archive is read: `read`.
  5. An archive error: the hot answer only, `unreadable`, one `console.log`
     line. It is never thrown and never turned into an empty answer.
  `mergeRows`, `mergeAggregate` and `mergeGroups` combine the two answers.
- Three routes are ported. Each response gains `archive: <state>`.
  - `GET /api/metrics/cost-breakdown`: rows mode gains `row_hash` and dedupes on
    `(box, row_hash)`. Grouped mode and the total sum each store's own
    aggregate. `truncated` is also true when one store returned 500 groups.
  - `GET /api/model-watch/usage`: the sums add.
  - `GET /api/jobs/:id`: events include archived events, in id order. The
    archive read is bounded by the job's `created_at` and orders by `+id`, so
    SQLite uses the `created_at` index and does not walk the table by rowid.
    This route is polled every 20 s by an open drill-down: a job older than
    1 day makes one archive MAX read per poll.
- `GET /api/jobs/:id/live` and every narrow, poll and action reader stay hot
  only.
- `worker/jobs/test/archive-readers.d/bh-6779.json` lists every FROM/JOIN of
  the three tables in the worker source, with its window class and status. The
  test fails on a new reader with no row. A later ticket adds its own fragment
  file in that directory.

## Known limits

- A row in both stores (between the archive copy and the hot delete) counts
  twice in a sum. Rows mode dedupes it.
- `ARCHIVE` is unbound in prod today, so all three routes answer as before,
  plus `archive: "unbound"`.

## Pending for C1 of #6779 (Blocked-by #6777)

- The `stage_events_daily` archive rule and its test (R5).
- `routes/cost` (`llm-spend`, `cost-anchored`, `cost-rows`), `routes/lane-spend`.
- The readers that JOIN a hot-only table: `lib/daily-digest/core-sections`,
  `routes/model-routes`, `lib/outcome-gap`.
- `readHistory` moves to #6777's `archiveMaxTime`, and the test archive fixture
  moves to the real `ensureArchiveTable`.
