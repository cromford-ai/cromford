export default [
  // BH-9911: a claude_cli_smoke row is the evidence of one canary soak (24 h
  // by default) for one CLI version. A version is promoted or dropped within
  // days, so a row past retention.claude_cli_smoke.days (90) has no reader and
  // is deleted, not archived. ~24 rows a day at most.
  {
    rule: "claude_cli_smoke.age", table: "claude_cli_smoke", key: "retention.claude_cli_smoke.days", def: 90,
    ids: "SELECT rowid AS id FROM claude_cli_smoke WHERE inserted_at < ?1 ORDER BY inserted_at LIMIT ?2",
    del: "DELETE FROM claude_cli_smoke WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
