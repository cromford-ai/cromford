export default [
  // BH-7429: a pool build record is a transport copy; the hub build dir is
  // the record of the build. A row the reap read has no reader left; a row
  // nobody read means the hub took the ssh path. No money, no history.
  {
    rule: "pool_record_files.reaped", table: "pool_record_files", key: "retention.pool_record_files.reaped_days", def: 1,
    ids: "SELECT id FROM pool_record_files WHERE reaped_at IS NOT NULL AND reaped_at < ?1 ORDER BY reaped_at LIMIT ?2",
    del: "DELETE FROM pool_record_files WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NOT NULL",
  },
  {
    rule: "pool_record_files.unread", table: "pool_record_files", key: "retention.pool_record_files.unread_days", def: 3,
    ids: "SELECT id FROM pool_record_files WHERE reaped_at IS NULL AND posted_at < ?1 ORDER BY posted_at LIMIT ?2",
    del: "DELETE FROM pool_record_files WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NULL",
  },
];
