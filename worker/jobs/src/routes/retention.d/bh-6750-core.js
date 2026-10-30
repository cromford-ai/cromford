export default [
  {
    rule: "wakes.age", table: "wakes", key: "retention.wakes.days", def: 30,
    ids: "SELECT id FROM wakes WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM wakes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "wakes.acked", table: "wakes", key: "retention.wakes.acked_days", def: 3,
    ids: "SELECT id FROM wakes WHERE acked_at IS NOT NULL AND acked_at < ?1 ORDER BY acked_at LIMIT ?2",
    del: "DELETE FROM wakes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "job_heartbeats.closed", table: "job_heartbeats", key: "retention.job_heartbeats.days", def: 30,
    ids: `SELECT h.job_id AS id FROM job_heartbeats h LEFT JOIN jobs j ON j.id = h.job_id
           WHERE h.beat_at < ?1 AND (j.id IS NULL OR j.status <> 'running')
           ORDER BY h.beat_at LIMIT ?2`,
    del: "DELETE FROM job_heartbeats WHERE job_id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "stage_events.closed", table: "stage_events", key: "retention.stage_events.days", def: 90,
    archive: "stage_events", archiveFlag: "retention.stage_events.archive",
    sel: "SELECT * FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))",
    ids: `SELECT e.id AS id FROM stage_events e LEFT JOIN jobs j ON j.id = e.job_id
           WHERE e.created_at < ?1 AND (j.id IS NULL OR j.status <> 'running')
           ORDER BY e.created_at LIMIT ?2`,
    rollup: `INSERT INTO stage_events_daily (day, stage, verdict, actor, n)
             SELECT substr(created_at, 1, 10), stage, COALESCE(verdict, ''), actor, COUNT(*)
               FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2, 3, 4
             ON CONFLICT (day, stage, verdict, actor) DO UPDATE SET n = n + excluded.n`,
    del: "DELETE FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "lane_ticks.stale", table: "lane_ticks", key: "retention.lane_ticks.days", def: 30,
    ids: "SELECT rowid AS id FROM lane_ticks WHERE last_tick_at < ?1 ORDER BY last_tick_at LIMIT ?2",
    del: "DELETE FROM lane_ticks WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "retention_runs.age", table: "retention_runs", key: "retention.retention_runs.days", def: 90,
    ids: "SELECT id FROM retention_runs WHERE started_at < ?1 ORDER BY started_at LIMIT ?2",
    del: "DELETE FROM retention_runs WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
