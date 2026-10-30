export default [
  // BH-7325: a migration-number reservation is a short claim; after 30 days its
  // number is on main, in a PR or unused, so the row is deleted, not archived.
  {
    rule: "migration_reservations.age", table: "migration_reservations", key: "retention.migration_reservations.days", def: 30,
    ids: "SELECT rowid AS id FROM migration_reservations WHERE reserved_at < ?1 ORDER BY reserved_at LIMIT ?2",
    del: "DELETE FROM migration_reservations WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
