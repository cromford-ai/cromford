export default [
  // BH-9800: the signal key audit trail is history, so it is copied to the
  // archive D1 before the delete; unbound, nothing is deleted. signal_keys
  // (at most projects x kinds rows; clear deletes a row) and signal_key_kinds
  // (a catalog) have no rule.
  {
    rule: "signal_key_audit.age", table: "signal_key_audit", key: "retention.signal_key_audit.days", def: 90,
    archive: "signal_key_audit", quietUnbound: true,
    ids: "SELECT id FROM signal_key_audit WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM signal_key_audit WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM signal_key_audit WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
