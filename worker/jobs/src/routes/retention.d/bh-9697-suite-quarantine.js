export default [
  // BH-9697: a released suite_quarantine row past
  // suite_quarantine.retention_days is deleted. An active row never goes: the
  // id read and the delete both require status 'released'. Released rows are
  // operational; they hold no money or history value past the window, so
  // there is no rollup. The id read uses idx_suite_quarantine_released; the
  // delete uses the PRIMARY KEY.
  {
    rule: "suite_quarantine.released", table: "suite_quarantine", key: "suite_quarantine.retention_days", def: 60,
    ids: `SELECT id FROM suite_quarantine WHERE status='released' AND released_at < ?1 ORDER BY released_at LIMIT ?2`,
    del: `DELETE FROM suite_quarantine WHERE id IN (SELECT value FROM json_each(?1)) AND status='released'`,
  },
];
