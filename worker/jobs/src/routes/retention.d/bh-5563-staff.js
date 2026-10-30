export default [
  // BH-5563: staff learning-loop history. An outcome goes only when it is past
  // the window, applied, and older than its agent's last change
  // (staff_agents.updated_at): the promotion read in staff-outcomes.js reads
  // the rows since that time, so it never loses one. resolved_at is the server
  // time of the insert, so per family the removed rows are always the oldest
  // ids, and the noise count after the newest kept marker does not change.
  {
    rule: "staff_outcomes.age", table: "staff_outcomes", key: "retention.staff_outcomes.days", def: 180,
    ids: `SELECT o.id AS id FROM staff_outcomes o LEFT JOIN staff_agents a ON a.name = o.agent
           WHERE o.resolved_at < ?1 AND o.applied = 1 AND (a.name IS NULL OR o.resolved_at < a.updated_at)
           ORDER BY o.resolved_at LIMIT ?2`,
    del: "DELETE FROM staff_outcomes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A pending promotion is never removed; a decided one is kept for its window.
  // BH-6825: a human decision row (staff_promotion_decisions) lives and dies
  // with its promotion, so each rule deletes it first, in the same batch.
  {
    rule: "staff_promotions.void", table: "staff_promotions", key: "retention.staff_promotions.void_days", def: 30,
    ids: "SELECT id FROM staff_promotions WHERE status = 'void' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    pre: ["DELETE FROM staff_promotion_decisions WHERE promotion_id IN (SELECT value FROM json_each(?1))"],
    del: "DELETE FROM staff_promotions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "staff_promotions.applied", table: "staff_promotions", key: "retention.staff_promotions.applied_days", def: 180,
    ids: "SELECT id FROM staff_promotions WHERE status = 'applied' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    pre: ["DELETE FROM staff_promotion_decisions WHERE promotion_id IN (SELECT value FROM json_each(?1))"],
    del: "DELETE FROM staff_promotions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A finished finding is the claim dedup for its fingerprint, so it stays a
  // year; a claimed or filed one is live work and never goes. The IN list is
  // the partial index's own WHERE, so the read uses idx_staff_findings_done.
  // Its children go first, in the same batch: the outcome row and the
  // 'staff:<fp>' decision row. Left behind, a re-filed finding would meet the
  // old outcome (409 ticket_mismatch every hour) and the old decision (INSERT
  // OR IGNORE keeps it, so the new choice is never counted).
  {
    rule: "staff_findings.done", table: "staff_findings", key: "retention.staff_findings.done_days", def: 365,
    ids: `SELECT id FROM staff_findings
           WHERE status IN ('digested','refused','unsupported','failed','merged','rejected','noise') AND updated_at < ?1
           ORDER BY updated_at LIMIT ?2`,
    pre: [
      `DELETE FROM staff_outcomes WHERE fingerprint IN
         (SELECT fingerprint FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1)))`,
      `DELETE FROM staff_decisions WHERE escalation_key IN
         (SELECT 'staff:' || fingerprint FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1)))`,
    ],
    del: "DELETE FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // Revoked and expired suppressions mute nothing; a pending one never goes.
  {
    rule: "staff_suppressions.revoked", table: "staff_suppressions", key: "retention.staff_suppressions.revoked_days", def: 180,
    ids: "SELECT id FROM staff_suppressions WHERE status = 'revoked' AND created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM staff_suppressions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "staff_suppressions.expired", table: "staff_suppressions", key: "retention.staff_suppressions.expired_days", def: 180,
    ids: "SELECT id FROM staff_suppressions WHERE status = 'active' AND expires_at < ?1 ORDER BY expires_at LIMIT ?2",
    del: "DELETE FROM staff_suppressions WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
