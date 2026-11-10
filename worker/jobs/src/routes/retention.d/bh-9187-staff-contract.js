export default [
  // BH-9187: staff metric samples are trend data: the scorecard reads the
  // latest one and the one 1..30 days back, so a sample past
  // retention.staff_metric_samples.days goes.
  {
    rule: "staff_metric_samples.age", table: "staff_metric_samples", key: "retention.staff_metric_samples.days", def: 90,
    ids: "SELECT id FROM staff_metric_samples WHERE sampled_at < ?1 ORDER BY sampled_at LIMIT ?2",
    del: "DELETE FROM staff_metric_samples WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A lever action is history, kept a year once it is settled. An unsettled
  // one is open work for the settle and is never removed. The WHERE is the
  // partial index's own, so the read uses idx_staff_lever_actions_settled.
  {
    rule: "staff_lever_actions.settled", table: "staff_lever_actions", key: "retention.staff_lever_actions.days", def: 365,
    ids: `SELECT id FROM staff_lever_actions WHERE settled_at IS NOT NULL AND settled_at < ?1
           ORDER BY settled_at LIMIT ?2`,
    del: "DELETE FROM staff_lever_actions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A seen row lives and dies with its finding: once staff_findings.done has
  // removed the finding, the seen row goes. A row with a finding never goes.
  {
    rule: "staff_finding_seen.orphan", table: "staff_finding_seen", key: "retention.staff_finding_seen.orphan_days", def: 1,
    ids: `SELECT s.rowid AS id FROM staff_finding_seen s LEFT JOIN staff_findings f ON f.fingerprint = s.fingerprint
           WHERE s.last_checked_at < ?1 AND f.id IS NULL ORDER BY s.last_checked_at LIMIT ?2`,
    del: "DELETE FROM staff_finding_seen WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
