export default [
  // BH-9064: an agent_call_ledger row is a dedup key whose value ends with the
  // replay window (1 h) and the K3 window (24 h); the spend is in cost_rows.
  // So a row past retention.agent_call_ledger.days is deleted, not archived.
  {
    rule: "agent_call_ledger.age", table: "agent_call_ledger", key: "retention.agent_call_ledger.days", def: 7,
    ids: "SELECT rowid AS id FROM agent_call_ledger WHERE last_at < ?1 ORDER BY last_at LIMIT ?2",
    del: "DELETE FROM agent_call_ledger WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
