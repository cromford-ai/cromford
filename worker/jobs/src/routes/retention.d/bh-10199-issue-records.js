export default [
  // BH-10199: an issue_records row is a cache of one GitHub thread's state.
  // A row with no write for retention.issue_records.days (30) is a thread no
  // webhook and no reader touched in a month: deleted, not archived. A deleted
  // row reads as no-record, and one GitHub read rebuilds it.
  {
    rule: "issue_records.age", table: "issue_records", key: "retention.issue_records.days", def: 30,
    ids: "SELECT id FROM issue_records WHERE refreshed_at < ?1 ORDER BY refreshed_at LIMIT ?2",
    del: "DELETE FROM issue_records WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A stored comment past retention.issue_comments.days (21) of its last write
  // or full read. A record the reader trusts was fully read within
  // issue_records.backfill_max_age_s (7 days), which rewrote seen_at of every
  // comment it holds, so this rule never cuts a trusted thread.
  {
    rule: "issue_comments.age", table: "issue_comments", key: "retention.issue_comments.days", def: 21,
    ids: "SELECT id FROM issue_comments WHERE seen_at < ?1 ORDER BY seen_at LIMIT ?2",
    del: "DELETE FROM issue_comments WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
