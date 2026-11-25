export default [
  // BH-9792: a perf_probe_warm row whose warmed_at is older than
  // perf_probe.retention_days (the settings row of the results rule; fallback
  // 90) is deleted. A row is the deploy watermark of bin/perf-probe-warm.sh: no
  // money or history value, so no archive. The id read uses the covering index
  // idx_perf_probe_warm_at; the delete uses the rowid.
  {
    rule: "perf_probe_warm.warmed_at", table: "perf_probe_warm", key: "perf_probe.retention_days", def: 90,
    ids: `SELECT rowid AS id FROM perf_probe_warm WHERE warmed_at < ?1 ORDER BY warmed_at LIMIT ?2`,
    del: `DELETE FROM perf_probe_warm WHERE rowid IN (SELECT value FROM json_each(?1))`,
  },
];
