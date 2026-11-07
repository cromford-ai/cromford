// BH-9076: d1_stmt_stats rows are sampled statement counts, read only by
// GET /api/d1/stmt-stats/top inside d1.stmt_stats_hours_max (14 days). An hour
// older than retention.d1_stmt_stats.days (seed 14; def is the fallback for
// that row) is deleted. The id read walks the PRIMARY KEY (hour, sql_hash).
// `hour` is 'YYYY-MM-DDTHH', so the ISO cutoff is cut to 13 characters.
// The rule name has no digit: bin/d1-retention.sh reads only names that
// match ^[a-z_]+\.[a-z_]+$.

export default [
  {
    rule: "stmt_stats.age", table: "d1_stmt_stats", key: "retention.d1_stmt_stats.days", def: 14,
    ids: "SELECT rowid AS id FROM d1_stmt_stats WHERE hour < substr(?1, 1, 13) ORDER BY hour LIMIT ?2",
    del: "DELETE FROM d1_stmt_stats WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
