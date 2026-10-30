export default [
  // BH-6744: a landing shadow decision is a diagnostic with no reader after
  // wave 5's replay window; not money or history, so it is deleted.
  {
    rule: "landing_decisions.age", table: "landing_decisions", key: "retention.landing_decisions.days", def: 90,
    ids: "SELECT id FROM landing_decisions WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM landing_decisions WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
