export default [
  // BH-7722: the Tackler decision ledger is history of record: a terminal row
  // past retention.unblock_decisions.days is copied to the archive D1, then
  // deleted. A claimed or escalated row never goes (an open claim or card).
  {
    rule: "unblock_decisions.age", table: "unblock_decisions", key: "retention.unblock_decisions.days", def: 180,
    archive: "unblock_decisions", quietUnbound: true,
    ids: `SELECT id FROM unblock_decisions WHERE created_at < ?1 AND outcome NOT IN ('claimed','escalated')
           ORDER BY created_at LIMIT ?2`,
    sel: "SELECT * FROM unblock_decisions WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM unblock_decisions WHERE id IN (SELECT value FROM json_each(?1)) AND outcome NOT IN ('claimed','escalated')",
  },
];
