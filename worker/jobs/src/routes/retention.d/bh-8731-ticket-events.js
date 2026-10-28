export default [
  // BH-8731: the ticket lifecycle ledger is history: an event older than
  // retention.ticket_events.days is copied to the archive D1, then deleted,
  // never only deleted (the unblock_decisions.age pattern). The ids read uses
  // idx_ticket_events_at (schema.d/*-bh-8731-ticket-events.sql).
  {
    rule: "ticket_events.age", table: "ticket_events", key: "retention.ticket_events.days", def: 180,
    archive: "ticket_events", quietUnbound: true,
    ids: "SELECT id FROM ticket_events WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM ticket_events WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM ticket_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
