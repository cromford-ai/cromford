export default [
  // BH-9262: an owner approval is an inbox row; the action the owner ran keeps its own audit rows, so nothing is archived.
  {
    rule: "owner_approvals.age", table: "owner_approvals", key: "retention.owner_approvals.days", def: 90,
    ids: "SELECT id FROM owner_approvals WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM owner_approvals WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
