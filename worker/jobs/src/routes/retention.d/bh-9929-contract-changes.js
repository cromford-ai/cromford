const COLS = `id, project, parent_ticket, step, pr_url, head_sha, classes, backup_ref, restore_ref,
  verdict, approved_by, created_at, updated_at`;

export default [
  // BH-9929: a contract_changes row is history (which step, which backup, who
  // approved it), so it is archived, never silently deleted. A row not updated
  // for retention.contract_changes.days (730) is copied to
  // contract_changes_archive in the same D1 batch, before the delete. The id
  // read is an index SEARCH on idx_contract_changes_updated; the delete uses
  // the PRIMARY KEY.
  {
    rule: "contract_changes.archive", table: "contract_changes", key: "retention.contract_changes.days", def: 730,
    ids: `SELECT id FROM contract_changes
           WHERE updated_at < ?1
           ORDER BY updated_at LIMIT ?2`,
    rollup: `INSERT OR IGNORE INTO contract_changes_archive (${COLS}, archived_at)
             SELECT ${COLS}, strftime('%Y-%m-%dT%H:%M:%SZ','now')
               FROM contract_changes WHERE id IN (SELECT value FROM json_each(?1))`,
    del: "DELETE FROM contract_changes WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
