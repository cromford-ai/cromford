export default [
  // BH-9063: suite_results is a cache of suite runs, keyed by input
  // fingerprint. A row past the window is a green no lookup reuses
  // (lib.suite-reuse.suite_reuse_max_age_h is at most 720 h) and a red no gate
  // reads. Not money or history. Served by idx_suite_results_updated.
  {
    rule: "suite_results.age", table: "suite_results", key: "retention.suite_results.days", def: 14,
    ids: "SELECT rowid AS id FROM suite_results WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    del: "DELETE FROM suite_results WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // BH-9063: one row per gate run (ran, reused, saved_s). Mission Control's
  // SUITE REUSE screen reads at most 60 days (routes/suite-reuse-saved.js
  // SAVED_DAYS_MAX), so the window keeps its full range. Served by
  // idx_suite_reuse_runs_created.
  {
    rule: "suite_reuse_runs.age", table: "suite_reuse_runs", key: "retention.suite_reuse_runs.days", def: 60,
    ids: "SELECT rowid AS id FROM suite_reuse_runs WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM suite_reuse_runs WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
