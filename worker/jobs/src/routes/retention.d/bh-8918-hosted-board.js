export default [
  // BH-8918: the hosted Board API's event log and Idempotency-Key answers.
  // Both are deleted after their window (180 days, the settings rows); neither
  // is money. Tickets and comments have no rule: they archive by archived_at
  // and are never deleted. The ids reads use idx_hosted_board_events_at and
  // idx_hosted_board_idem_created (schema.d/*-bh-8918-hosted-board.sql).
  {
    rule: "hosted_board_events.age", table: "hosted_board_events", key: "retention.hosted_board_events.days", def: 180,
    ids: "SELECT id FROM hosted_board_events WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM hosted_board_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "hosted_board_idem.age", table: "hosted_board_idem", key: "retention.hosted_board_idem.days", def: 180,
    ids: "SELECT id FROM hosted_board_idem WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM hosted_board_idem WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
