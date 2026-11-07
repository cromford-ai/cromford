export default [
  // BH-9047: a disprove-pass row is shadow measurement, not money or history.
  // The ids read uses idx_review_disprove_runs_created.
  {
    rule: "review_disprove_runs.age", table: "review_disprove_runs", key: "retention.review_disprove_runs.days", def: 90,
    ids: "SELECT id FROM review_disprove_runs WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM review_disprove_runs WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
