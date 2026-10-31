export default [
  // BH-7260: the PM flesh-out ledger. Each row is a billed model call (cost_usd
  // is money) and its result: archived, never only deleted. The ids read uses
  // idx_pm_runs_created (schema.d/*-bh-7260-pm-runs.sql).
  {
    rule: "pm_runs.age", table: "pm_runs", key: "pm.retention_days", def: 180,
    archive: "pm_runs", quietUnbound: true,
    ids: "SELECT id FROM pm_runs WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM pm_runs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM pm_runs WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
