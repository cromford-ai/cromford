export default [
  // BH-6977: an edge's `at` moves on every write; a hold's `at` is its comment's time.
  {
    rule: "ticket_edges.age", table: "ticket_edges", key: "retention.ticket_edges.days", def: 365,
    ids: "SELECT id FROM ticket_edges WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM ticket_edges WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "ticket_holds.age", table: "ticket_holds", key: "retention.ticket_holds.days", def: 365,
    ids: "SELECT id FROM ticket_holds WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM ticket_holds WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
