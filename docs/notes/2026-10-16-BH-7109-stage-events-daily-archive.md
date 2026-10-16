# stage_events_daily archive rule (BH-7109, Scope 4 + R5 of BH-6779)

Doc: OPERATING

## What changed

- `POST /api/retention/run` has one more rule, `stage_events_daily.archive`
  (`worker/jobs/src/routes/retention.js`). It is off by default.
- The settings row `retention.stage_events_daily.archive_days` (seed `'0'`,
  fragment `worker/jobs/schema.d/202610162010-bh-7109-archive-daily.sql`) sets
  the window in days. 0 = off.
- When the rule is on, a daily rollup row moves when its whole `day` is older
  than the cutoff date. The row on the cutoff date stays.
- A day also moves only when it is older than the oldest event still in
  `stage_events` (`MIN(created_at)`, one read on `idx_events_created`). Every
  event insert stamps `created_at` with the server time, so such a day can get
  no more rollups. A day that still has events stays in hot: an event of a
  running job, or a backlog that `retention.max_rows` drains over runs. Without
  this gate, a later rollup for an archived day makes a new hot row. Its `n`
  can equal the archived `n`, and the count-back would delete it as "already
  copied". Tests A11 and A12 cover this.
- So `archive_days` below `retention.stage_events.days` loses nothing: the
  gate holds a day back until its events are rolled up.
- The move is in `worker/jobs/src/lib/archive-daily.js`, for each batch:
  1. Read the hot rows by rowid.
  2. Create the archive table `stage_events_daily` in env.ARCHIVE if absent
     (the hot columns plus `archived_at`, the natural key as primary key).
  3. Copy the batch in one `INSERT OR IGNORE` statement.
  4. Count the rows back by key AND `n`.
  5. Delete from hot only the rows the archive holds with the same `n`, and
     only while the hot `n` still matches that value.

## Failure behavior

- ARCHIVE unbound (absent, or no `prepare`): the rule records
  `error = "archive not bound"`, reads nothing and deletes nothing. A dry run
  records the same error.
- A failed copy: `error = "archive copy failed: <msg>"`. Nothing in that batch
  is deleted.
- A key that the archive holds with a different `n` (a hand edit), or a hot
  row whose `n` grew after the copy: the row stays in hot. The rule records
  `archive copy not verified for <k> of <m> rows; those rows stay` and stops
  for this run. The rule reports it on every run until a person merges the two
  counts. The archived row is never overwritten. While such a row stays, it is
  in the first batch of every run (the read is `ORDER BY day`), so each run
  moves at most `retention.batch - 1` rows.
- A copy that landed while the hot delete failed: the next run finds the same
  values in the archive and deletes the hot rows. No duplicate is written.
- The hub lane `bin/d1-retention.sh` raises its usual warn alert
  `d1-retention:stage_events_daily.archive` for a run with an error.

## Operator steps to turn it on

1. Bind the archive D1 as `ARCHIVE` in `worker/jobs/wrangler.jsonc` and deploy.
2. Set `retention.stage_events_daily.archive_days` (for example `400`).
3. Keep `retention.dry_run` at `1` for one run and read the count.

## Why not `archiveCopy` and `ARCHIVE_TABLES`

BH-6779 named those helpers. They are only in open PR #6777 (BH-6774), not on
main. This change ships a mover for this one table. The archive table has the
same shape as #6777's archive tables, so a later change can point this rule at
`archiveCopy`.
