export default [
  // BH-10215: a pr_base_seqs row is a cache key (the base sequence of one
  // repo and base branch), not money or history. A deleted row reads as "no
  // row", which the conductor treats as a miss: one GitHub read, then the next
  // push writes the row again. So a row past retention.pr_base_seqs.days is
  // deleted, not archived. The id read uses idx_pr_base_seqs_updated; the
  // delete is by rowid.
  {
    rule: "pr_base_seqs.age", table: "pr_base_seqs", key: "retention.pr_base_seqs.days", def: 30,
    ids: "SELECT rowid AS id FROM pr_base_seqs WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    del: "DELETE FROM pr_base_seqs WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
