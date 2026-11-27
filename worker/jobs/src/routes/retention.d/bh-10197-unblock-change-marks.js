export default [
  // BH-10197: an unblock_change_marks row is the last change mark the unblock
  // lane read for one PR at one site. It is a cache: a deleted row reads as
  // first seen, and one GitHub read rebuilds it. A row past
  // retention.unblock_change_marks.days (14) is a PR quiet for two weeks, so it
  // is deleted, not archived. About 30,000 rows at most.
  {
    rule: "unblock_change_marks.age", table: "unblock_change_marks", key: "retention.unblock_change_marks.days", def: 14,
    ids: "SELECT id FROM unblock_change_marks WHERE checked_at < ?1 ORDER BY checked_at LIMIT ?2",
    del: "DELETE FROM unblock_change_marks WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
