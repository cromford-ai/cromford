# BH-7035 slice C0: the remaining wide history readers read the archive

Doc: none

## What changed

C0 of #6779 put three history readers on `worker/jobs/src/lib/archive-read.js`
and left nine wide readers `pending` in the inventory
(`worker/jobs/test/archive-readers.d/bh-6779.json`). This slice ports the
nine readers that do not need #6777:

| reader | file | archive state in the answer |
|---|---|---|
| `GET /api/metrics/lane-spend` (1 read per 90-lane chunk) | `routes/lane-spend.js` | `archive` |
| daily digest `spend` (totals, top tickets) | `lib/daily-digest/core-sections.js` | `spend.archive` |
| daily digest `autonomy` (requeue count and rows, `stage_events` actors) | `lib/daily-digest/core-sections.js` | `autonomy.archive` |
| `GET /api/model-routes?unrouted_since=` | `routes/model-routes.js` | `unrouted_archive` (only with `unrouted_since`) |
| `GET /api/metrics/outcome-gap` (cohort, unpriced count) | `lib/outcome-gap.js`, `routes/outcome-gap.js` | `archive` |

Each state is one of `unbound`, `not-needed`, `read`, `unreadable`, as in C0.
A reader with more than one read reports the worst one
(`unreadable` > `read` > `not-needed` > `unbound`). `ARCHIVE` is unbound in
prod today, so every answer is the same as before plus `"unbound"`. The two
daily-digest fixtures in `tests/fixtures/daily-digest/` carry the new key.

## The helper

- `archiveReach(env, { table, since, now })` runs the decision rule's steps
  1-4 (and the MAX error) with no data read. A reader with more than one
  statement asks once and passes the answer to `readHistory` as `reach`.
- `readHistory` without `reach` now runs the hot read and the reach check in
  parallel. With `reach` it runs no MAX read, and with `reach: "reach"` it
  runs the hot and archive reads in parallel. Return shape and states do not
  change.
- `mergeAggregate` has a new kind, `union`, for `group_concat(DISTINCT ...)`
  columns.
- `worstState(states)` folds several states into one.

## Hot-only tables

`jobs`, `model_routes`, `job_artifacts` and `ledgers` are not in the archive.
A reader that JOINs one of them runs the archive read without it. Then ONE
hot statement over a `json_each` list of the archive's keys applies the same
predicate: the requeue rows' `jobs` lookup, the `model_routes` rung-0 check,
and `gapUnmergedSql` (outcome-gap's merged-PR check).

The outcome gap's `HAVING SUM(cost_usd) > min_usd` cannot run per store. A
ticket can pass it only on the combined sum. So, only when the archive is in
reach, `gapGroupsSql` groups both stores with no HAVING (cap 5001 per side).
`mergeGapGroups` merges them and applies `passesHaving`, then
`gapUnmergedSql` runs. When the archive is not in reach, the route runs
`gapSql` as before. A side at its cap sets `truncated`.

## Left for C1 of #7035 (Blocked-by: #6777)

- The six `routes/cost.js` readers. They stay `pending`, slice `C1 of #7035`.
- Scope 4 (the `stage_events_daily` archive rule) and R5. Both need
  `archiveCopy` and `ARCHIVE_TABLES` from #6777.

## Tests

`worker/jobs/test/archive-readers.bh-7035.test.js` (A1-A3, O1-O3, R2, R3, R4,
R6) and `tests/archive-readers.bh-7035-test.sh`. The new archive-only
statements are in `worker/jobs/test/archive-readers.d/bh-7035.json`.
