export default [
  // BH-6889: a machine's alert line, once the hub replayed it into ALERTS.log
  // (applied_at set), and a line the hub never replayed (the publisher off).
  {
    rule: "alert_lines.applied", table: "alert_lines", key: "retention.alert_lines.applied_days", def: 7,
    ids: "SELECT id FROM alert_lines WHERE applied_at < ?1 ORDER BY applied_at LIMIT ?2",
    del: "DELETE FROM alert_lines WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "alert_lines.unapplied", table: "alert_lines", key: "retention.alert_lines.unapplied_days", def: 30,
    ids: "SELECT id FROM alert_lines WHERE applied_at IS NULL AND created_at < ?1 ORDER BY id LIMIT ?2",
    del: "DELETE FROM alert_lines WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
