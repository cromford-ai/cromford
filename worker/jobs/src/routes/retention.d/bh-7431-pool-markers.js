export default [
  // BH-7431: the pool's once-markers and wait clocks. The after-gate ceiling is
  // 6 h and the cap window 24 h, so a 30-day-old marker gates nothing. Reads on
  // idx_pool_markers_updated; deletes by rowid. No money in these rows.
  {
    rule: "pool_markers.age", table: "pool_markers", key: "retention.pool_markers.days", def: 30,
    ids: "SELECT rowid AS id FROM pool_markers WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    del: "DELETE FROM pool_markers WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
