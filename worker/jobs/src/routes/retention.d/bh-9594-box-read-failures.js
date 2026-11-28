export default [
  // BH-9594: a could-not-read row is diagnostic (which box failed which read,
  // when); 14 days covers a failover investigation. Not money, not history.
  {
    rule: "box_read_failures.age", table: "box_read_failures", key: "retention.box_read_failures.days", def: 14,
    ids: "SELECT id FROM box_read_failures WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM box_read_failures WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
