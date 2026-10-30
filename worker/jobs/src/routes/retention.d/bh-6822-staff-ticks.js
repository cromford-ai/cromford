export default [
  // BH-6822: one row per staff heartbeat tick, the agent page's timeline. It is
  // heartbeat history, not money (cost stays in cost_rows), so 90 days is enough.
  {
    rule: "staff_ticks.age", table: "staff_ticks", key: "retention.staff_ticks.days", def: 90,
    ids: "SELECT id FROM staff_ticks WHERE started_at < ?1 ORDER BY started_at LIMIT ?2",
    del: "DELETE FROM staff_ticks WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
