export default [
  // BH-6739: a split-ticket row is the "filed once" memory; after a year a still-hot path may file again.
  {
    rule: "hotspot_tickets.age", table: "hotspot_tickets", key: "retention.hotspot_tickets.days", def: 365,
    ids: "SELECT rowid AS id FROM hotspot_tickets WHERE filed_at < ?1 ORDER BY filed_at LIMIT ?2",
    del: "DELETE FROM hotspot_tickets WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
