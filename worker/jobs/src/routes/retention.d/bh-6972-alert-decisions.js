export default [
  // BH-6972: a component-watch decision is a diagnostic; the audit of each
  // state change stays in alert_actions, so the row is deleted, not archived.
  {
    rule: "alert_decisions.age", table: "alert_decisions", key: "retention.alert_decisions.days", def: 90,
    ids: "SELECT id FROM alert_decisions WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM alert_decisions WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
