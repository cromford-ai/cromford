# Wakes reads: claim cursor, claim indexes, summary table, dead cursors (BH-6799)

Doc: EVENTS

## The gap

On 2026-10-14 the wakes routes were the largest readers left on the
harness-jobs D1 after BH-6727:

- `POST /api/wakes/claim` answered `scanned_top` = the last MATCHING id. A box
  whose repos rang rarely kept its cursor below every other repo's rows, and
  each poll re-read them (project-6: 67,159 rows behind, 4,557 rows a call).
- The claim's `lower(repo) IN (...) OR kind IN (...)` had no index to serve it.
- `GET /api/wakes/summary` aggregated every wake in its window on every call.
- `probe-operator-mac` had a cursor 327,178 rows behind `MAX(id)` and nothing said so.

## What changed

- **Claim cursor.** The claim reads `MAX(id)` before its scan and bounds the
  scan with `id <= MAX`. A scan that returns fewer than `limit` rows answers
  `scanned_top` = `MAX(cursor, MAX(id))`. A capped scan answers its last
  returned id, as before. A row written after the `MAX` read is above it, so
  the next claim scans it. `bin/wake-loop.sh` is not changed: it already PUTs
  `scanned_top`.
- **Claim indexes** (`worker/jobs/schema.d/202610150809-bh-6799-wakes-reads.sql`):
  `idx_wakes_repo_lc_id ON wakes(lower(repo), id)` and
  `idx_wakes_kind_id ON wakes(kind, id)`. The claim plans as a MULTI-INDEX OR
  of two range SEARCHes. The first is an expression index, not a stored
  `repo_lc` column: no wake writer changes and no back-fill runs.
- **Summary table.** `wake_repo_last(repo PRIMARY KEY, last_id, last_at, kinds)`.
  Each summary call folds the wakes above `MAX(last_id)` into it (one upsert,
  a rowid range read) and then answers from it alone. The first call after the
  deploy reads the history once. Rows are `{repo, last_id, last_at, kinds}`;
  there is no per-window count `n` any more. `kinds` is every kind the repo
  ever rang with.
- **pr-snapshot.** `bin/lib/pr-snapshot-wakes.sh` reads the summary once per
  refresh, for 168 hours, before any page. When the row for its repo (byte for
  byte) has a digit `last_id` that is not above its own `wakes.wm`, it skips the
  `/api/wakes?since=` page read. Every other case pages as before.
- **`wakes_summary`** (`bin/lib/jobs/queue.sh`) prints a 5th TSV column,
  `last_id`. A field the worker did not send prints `-`.
- **Dead cursors.** `POST /api/wakes/prune` (the daily doorbell lane) also
  deletes each `wake_cursors` row whose cursor is below `MIN(wakes.id)`, and
  answers `cursors_deleted`. An empty `wakes` deletes none.
- **Stale cursor alert.** `GET /api/wakes/cursor?all=1` lists every cursor with
  its lag and a `stale` flag. `bin/doorbell-coverage-check.sh` reads it after the
  prune and writes one ALERTS line per stale box per UTC day. A failed read is
  one LOG line (`cursor-lag check failed`) and no alert.

## Settings rows

| Key | Default | Meaning |
|---|---|---|
| `wakes.cursor_lag_alert_rows` | 10000 | A cursor more than this many rows behind `MAX(wakes.id)` can be stale. |
| `wakes.cursor_lag_alert_s` | 3600 | It is stale only when it has also not moved for this many seconds. |

A value that is not a whole number uses the default.

## Not proven by the PR

The ticket's proof (D1 rows read per hour and the largest cursor lag, two hours
after the deploy) needs the deploy. Measure it with the
`d1AnalyticsAdaptiveGroups` query after the worker is live.
