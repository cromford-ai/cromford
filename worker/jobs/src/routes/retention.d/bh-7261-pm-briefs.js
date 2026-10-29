export default [
  // BH-7261: the PM agent's weekly briefs and their moves are history (what
  // was proposed and what the operator decided): archived, never only deleted.
  {
    rule: "pm_briefs.age", table: "pm_briefs", key: "pm.brief_retention_days", def: 365,
    archive: "pm_briefs", quietUnbound: true,
    ids: "SELECT id FROM pm_briefs WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM pm_briefs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM pm_briefs WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "pm_moves.age", table: "pm_moves", key: "pm.brief_retention_days", def: 365,
    archive: "pm_moves", quietUnbound: true,
    ids: "SELECT id FROM pm_moves WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM pm_moves WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM pm_moves WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
