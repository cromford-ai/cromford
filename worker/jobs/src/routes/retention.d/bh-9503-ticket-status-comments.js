export default [
  // BH-9503: a ticket_status_comments row is a delivery pointer (which GitHub
  // comment carries a ticket's status, and the fingerprint last written). The
  // comment stays on GitHub and a lost row is found again by its marker, so a
  // row past retention.ticket_status_comments.days is deleted, not archived.
  // The id read uses idx_ticket_status_comments_updated; the delete is by rowid.
  {
    rule: "ticket_status_comments.age", table: "ticket_status_comments", key: "retention.ticket_status_comments.days", def: 90,
    ids: "SELECT rowid AS id FROM ticket_status_comments WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    del: "DELETE FROM ticket_status_comments WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
