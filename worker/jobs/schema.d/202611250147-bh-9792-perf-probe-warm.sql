-- ── BH-9792: the post-deploy warm-up watermark of the perf probe ───────────
-- bin/perf-probe-warm.sh (a hub cron lane, every minute, a poll every
-- PERF_PROBE_WARM_POLL_MIN minutes) reads the newest GitHub deployment of a
-- project row in catalog/perf-probe.d/. A new deployment id gets one row
-- here: outcome 'warmed' after the health preflight and both route passes,
-- or 'deploy-failed' when its newest status is failure, error or inactive.
-- The natural key is (project, deployment_id); POST /api/perf-probe/warm is
-- INSERT OR IGNORE, so a repeat never changes the first row. The lane
-- compares only the newest id with the newest row, so a deployment is warmed
-- once. Route: src/routes/perf-probe-warm.js.
-- Note: docs/notes/2026-11-17-BH-9786-perf-probe.md (Warm-up and keep-warm).
--
-- INDEXES. Each read and the index that serves it:
--   newest row of a project         WHERE project=? ORDER BY warmed_at DESC
--                                    LIMIT 1 (GET /api/perf-probe/warm)
--                                    idx_perf_probe_warm_latest
--   insert                          INSERT OR IGNORE: the PRIMARY KEY
--                                    (sqlite_autoindex_perf_probe_warm_1)
--   retention ids                   WHERE warmed_at < ? ORDER BY warmed_at
--                                    LIMIT ?   idx_perf_probe_warm_at
--   retention delete                WHERE rowid IN (json_each): the rowid
-- EXPLAIN QUERY PLAN at 20,000 seeded rows (20 projects x 1,000 deploys,
-- ANALYZE; worker/jobs/test/perf-probe-warm.bh-9792.test.js W6w):
--   latest     SEARCH perf_probe_warm USING INDEX idx_perf_probe_warm_latest (project=?)
--   retention  SEARCH perf_probe_warm USING COVERING INDEX idx_perf_probe_warm_at (warmed_at<?)
--   delete     SEARCH perf_probe_warm USING INTEGER PRIMARY KEY (rowid=?)
-- No SCAN perf_probe_warm, no temp b-tree.
--
-- 12-MONTH SIZE: about 16 deploys a day for a busy project, so about 5,800
-- rows a year per project without retention, about 1,500 live with it.
-- RETENTION (retention.d/bh-9792-perf-probe-warm.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a row whose warmed_at
-- is older than perf_probe.retention_days (90, the row the results rule reads;
-- no new settings row) is deleted. A row is a watermark: no money or history
-- value. The cost of a deleted watermark is one more warm-up of a deployment
-- that is 90 days old.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS, so a
-- re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS perf_probe_warm (
  project TEXT NOT NULL,
  deployment_id TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('warmed','deploy-failed')),
  routes INTEGER NOT NULL DEFAULT 0,
  over INTEGER NOT NULL DEFAULT 0,
  warmed_at TEXT NOT NULL,
  PRIMARY KEY (project, deployment_id)
);
CREATE INDEX IF NOT EXISTS idx_perf_probe_warm_latest ON perf_probe_warm(project, warmed_at);
CREATE INDEX IF NOT EXISTS idx_perf_probe_warm_at ON perf_probe_warm(warmed_at);
