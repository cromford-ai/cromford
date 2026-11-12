const COLS = `id, repo, key, lane, reason, gate_class, question, question_fp, recommended, reasons_json,
  default_answer, deadline_at, review_at, status, answer, answered_by, comment_posted, created_at,
  resolved_at, asked_again_at`;

export default [
  // BH-9559: a resolved human gate (answered, defaulted, expired-irreversible)
  // past human_gate.retention_days is copied to human_gates_archive in the
  // same D1 batch, before the delete. An open gate never moves: the id read
  // and the delete both refuse status 'open'. The id read is an
  // index SEARCH on status (idx_human_gates_review or _open_created); the delete uses the PRIMARY KEY.
  {
    rule: "human_gates.archive", table: "human_gates", key: "human_gate.retention_days", def: 90,
    ids: `SELECT id FROM human_gates
           WHERE status IN ('answered','defaulted','expired-irreversible')
             AND COALESCE(resolved_at, created_at) < ?1
           ORDER BY created_at LIMIT ?2`,
    rollup: `INSERT OR IGNORE INTO human_gates_archive (${COLS}, archived_at)
             SELECT ${COLS}, strftime('%Y-%m-%dT%H:%M:%SZ','now')
               FROM human_gates WHERE id IN (SELECT value FROM json_each(?1)) AND status != 'open'`,
    del: "DELETE FROM human_gates WHERE id IN (SELECT value FROM json_each(?1)) AND status != 'open'",
  },
];
