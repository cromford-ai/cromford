export default [
  // BH-9154: a lead_ticket_verdicts row is read only inside the ticket replay
  // window (24 h, at most 7 days); the verdict itself stays in verdicts. So a
  // row past retention.lead_ticket_verdicts.days is deleted, not archived.
  {
    rule: "lead_ticket_verdicts.age", table: "lead_ticket_verdicts", key: "retention.lead_ticket_verdicts.days", def: 7,
    ids: "SELECT rowid AS id FROM lead_ticket_verdicts WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM lead_ticket_verdicts WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
