export default [
  // Staff autonomy and delegation changes: governance history made by a human,
  // tens of rows a year. The agent page reads the newest 20, so three years
  // keep every change anyone asks about. retention.dry_run applies.
  {
    rule: "staff_autonomy_changes.age", table: "staff_autonomy_changes", key: "retention.staff_autonomy_changes.days", def: 1095,
    ids: "SELECT id FROM staff_autonomy_changes WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM staff_autonomy_changes WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
