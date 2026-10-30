export default [
  // BH-8067: the PR record is a cache of GitHub-owned state; a deleted row
  // reads as unknown and one GitHub read rebuilds it. The closed delete repeats
  // the state test, so a PR reopened between the id read and the delete stays.
  {
    rule: "pr_records.closed", table: "pr_records", key: "retention.pr_records.closed_days", def: 14,
    ids: "SELECT id FROM pr_records WHERE state IN ('closed','merged') AND refreshed_at < ?1 ORDER BY state, refreshed_at LIMIT ?2",
    del: "DELETE FROM pr_records WHERE id IN (SELECT value FROM json_each(?1)) AND state IN ('closed','merged')",
  },
  {
    rule: "pr_records.age", table: "pr_records", key: "retention.pr_records.days", def: 90,
    ids: "SELECT id FROM pr_records WHERE refreshed_at < ?1 ORDER BY refreshed_at LIMIT ?2",
    del: "DELETE FROM pr_records WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
