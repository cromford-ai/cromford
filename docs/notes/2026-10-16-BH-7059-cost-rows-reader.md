# BH-7059 slice C1: GET /api/metrics/cost-rows reads the archive

Doc: none

## What changed

C0 (#7071) ported five of the six `routes/cost.js` history readers. This
slice ports the sixth: `GET /api/metrics/cost-rows`, the page of rows. Its
inventory row in `worker/jobs/test/archive-readers.d/bh-6779.json` is now
`ported`.

- The `where`, `binds` and `lim` build and the SQL text do not change. The
  read goes through `readHistory` from `worker/jobs/src/lib/archive-read.js`.
- The archive is read only when `since` is absent (a key lookup such as
  `?box=` or `?lane_id=`) or older than 1 day. A poll with a recent `since`
  makes 0 archive calls.
- `mergeRows` merges the two answers. Key `(box, row_hash)`: the hot copy
  wins. Order `ts` newest first. Cap `limit` (1..2000, as before).
- An archive row loses `archived_at` before it is returned. A merged row has
  the same keys as a hot row, so `bin/lib/cost-rows-read.sh`,
  `bin/budget-defaults.sh` and `bin/cost-rows-lane-backfill.sh` read it as
  before.
- The response has one new key, `archive`: `unbound`, `not-needed`, `read` or
  `unreadable`. A failed archive read gives HTTP 200, the hot page and
  `unreadable`.
- `ARCHIVE` is unbound in prod until #6777 merges. Until then the route runs
  today's SQL with 0 archive calls, plus `"archive": "unbound"`.

Tests: `worker/jobs/test/archive-readers-cost-rows.bh-7059.test.js` (R2 same
answer as all-hot, dedupe on `(box, row_hash)`, cap, `until` paging; R3 0
archive calls on poll windows; R4 unbound equals main's SQL; R5u unreadable;
R6 EXPLAIN at `LIVE.cost_rows` archive volume uses `idx_cost_rows_ts`).

## For #6777 (BH-6774 C0)

On rebase, take main's `GET /api/metrics/cost-rows` handler. #6777's version
reads `env.ARCHIVE` in the route, which test R1d refuses. Keep #6777's
`POST /api/metrics/cost-rows` hunk and its import line. One behaviour of
#6777's version is not kept: it skipped the archive when a full page's oldest
row was newer than every archived ts. `readHistory` skips on `since` and the
archive MAX instead. That costs at most one extra archive read on a full
page, and only when `ARCHIVE` is bound.

## What is left

- Archive indexes for key lookups with no `since` (`box`, `ticket`,
  `lane_id`, `guard_fp`, `runner` ...). #6777's archive table carries
  `idx_cost_rows_ts` and its primary key `(box, row_hash)` only, so a lookup
  on another key walks `idx_cost_rows_ts` newest first. The next
  #6777-dependent slice must add archive indexes that match the hot filter
  indexes.
- Scope 4 (the `stage_events_daily` archive rule) and R5 (its test) need
  `archiveCopy` and `ARCHIVE_TABLES` from #6777. They go to the next slice of
  #7059. Blocked-by: #6777 (hard).
