# D1 hot path
<!-- owner: BH-9067.4 (BH-9076, PR #9201; filled by BH-9224) -->

This slice measures which statements read the rows of the jobs D1. It adds a
sampled statement counter and pins 20 hot statements to an index under
`EXPLAIN QUERY PLAN`. It also gives every `worker/jobs/schema.d/` table a
retention rule or a written `-- no-retention:` reason.

The full design is in
[docs/notes/2026-11-07-BH-9076-d1-hot.md](../notes/2026-11-07-BH-9076-d1-hot.md).
This file is a summary. The note is the single source for the knob table and
the 20-statement table.

## Surface

- Route: `GET /api/d1/stmt-stats/top?hours=24&n=20` (bearer). It answers the
  sampled statements by calls.
- Table: `d1_stmt_stats`, key `(hour, sql_hash)`.
- Knob: `d1.stmt_stats_sample_pct` (seed 1, 0 = off).
- Retention: rule `stmt_stats.age`, window `retention.d1_stmt_stats.days`
  (seed 14).

## Files

- `worker/jobs/src/lib/stmt-stats.js`: the counter.
- `worker/jobs/src/routes/d1-stmt-stats.js`: the `/top` route.
- `worker/jobs/test/hot-statements-explain.bh-9076.test.js`: the 20 hot
  statements under EXPLAIN.
- `worker/jobs/test/stmt-stats.bh-9076.test.js`: the counter and the route.
- `worker/jobs/test/d1-retention-coverage.bh-9076.test.js`: a rule or a reason
  for every table.

## Owed

- The 24 h numbers after the deploy are owed, not measured. The baseline is
  2.86 billion rows read per day and 873 HTTP 500 on 2026-11-04. Read `/top`
  and the D1 dashboard one day after the deploy that applies the schema
  fragments.
- The summary tables in section 4 of the note are owed.

## Links

- Design note: [2026-11-07-BH-9076-d1-hot.md](../notes/2026-11-07-BH-9076-d1-hot.md)
- Verification map: [BH-9067.4](../verification-map/entries/BH-9067.4.md)
- PR #9201 (BH-9076)
