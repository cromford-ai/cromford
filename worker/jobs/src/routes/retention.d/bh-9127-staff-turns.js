export default [
  // BH-9127: one row per Archie turn, the agent page's timeline. It is activity
  // history, not money (cost stays in cost_rows), so 90 days is enough. The
  // window is the settings row retention.staff_turns.days; 90 is its fallback.
  {
    rule: "staff_turns.age", table: "staff_turns", key: "retention.staff_turns.days", def: 90,
    ids: "SELECT id FROM staff_turns WHERE started_at < ?1 ORDER BY started_at LIMIT ?2",
    del: "DELETE FROM staff_turns WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
