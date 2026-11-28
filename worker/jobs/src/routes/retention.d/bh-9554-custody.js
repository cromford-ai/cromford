export default [
  // BH-9554: a settled custody row (merged or closed) is ownership state with
  // no value once the ticket has ended; custody_actions keeps its history. An
  // open row (settled_at NULL) is never a candidate. The ids read uses
  // idx_ticket_custody_settled (schema.d/*-bh-9554-custody.sql).
  {
    rule: "ticket_custody.settled", table: "ticket_custody", key: "retention.ticket_custody.settled_days", def: 7,
    ids: "SELECT id FROM ticket_custody WHERE settled_at < ?1 ORDER BY settled_at LIMIT ?2",
    del: "DELETE FROM ticket_custody WHERE id IN (SELECT value FROM json_each(?1)) AND settled_at IS NOT NULL",
  },
  // BH-9554: the custody action log is history: a row older than
  // retention.custody_actions.days is copied to the archive D1, then deleted,
  // never only deleted (the ticket_events.age pattern). The ids read uses
  // idx_custody_actions_at.
  {
    rule: "custody_actions.age", table: "custody_actions", key: "retention.custody_actions.days", def: 90,
    archive: "custody_actions", quietUnbound: true,
    ids: "SELECT id FROM custody_actions WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM custody_actions WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM custody_actions WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
