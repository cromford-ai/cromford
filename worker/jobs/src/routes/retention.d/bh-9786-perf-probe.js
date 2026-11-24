export default [
  // BH-9786: a perf_probe_results row whose day is older than
  // perf_probe.retention_days (90) is deleted. The rows are operational
  // timing samples; they hold no money or history value past the window, so
  // there is no rollup. day is YYYY-MM-DD and the cutoff an ISO timestamp, so
  // `day < cutoff` keeps every day after the cutoff's date. The id read uses
  // idx_perf_probe_results_day; the delete uses the PRIMARY KEY.
  {
    rule: "perf_probe_results.day", table: "perf_probe_results", key: "perf_probe.retention_days", def: 90,
    ids: `SELECT id FROM perf_probe_results WHERE day < ?1 ORDER BY day LIMIT ?2`,
    del: `DELETE FROM perf_probe_results WHERE id IN (SELECT value FROM json_each(?1))`,
  },
];
