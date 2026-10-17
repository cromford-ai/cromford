-- BH-7164: three harness-jobs read shapes over 5,000 rows a call (live
-- 2026-10-16). Additive only.
--
-- GET /api/artifacts: `a.artifact_kind=? [AND a.updated_at>?] ... ORDER BY
-- a.updated_at DESC LIMIT n`. With idx_artifacts_ref the route read every
-- artifact of the kind and sorted them all before the LIMIT (8,293 and 12,072
-- rows a call). This index walks the kind newest first and stops at the LIMIT.
CREATE INDEX IF NOT EXISTS idx_artifacts_kind_updated ON job_artifacts(artifact_kind, updated_at);

-- GET /api/progress/stamps (cost section) summed every priced cost_rows row
-- in its widest window on every call (129,155 rows a call). It now folds the
-- cost_rows rows above its watermark into these hourly buckets and reads the
-- buckets plus the raw rows of the partial hours at the window edges
-- (worker/jobs/src/lib/cost-hourly.js). PRICED rows only: ts not NULL,
-- cost_usd > 0, project not NULL or ''. hour = substr(ts, 1, 13).
-- It is a cache: cost_rows keeps every source row. Retention rule
-- cost_project_hourly.age (retention.cost_project_hourly.days) removes old buckets.
CREATE TABLE IF NOT EXISTS cost_project_hourly (
  project TEXT NOT NULL,
  hour TEXT NOT NULL,              -- 'YYYY-MM-DDTHH', substr(ts, 1, 13)
  usd REAL NOT NULL,               -- SUM(cost_usd) of the bucket's rows
  n INTEGER NOT NULL,              -- the bucket's row count
  max_ts TEXT NOT NULL,            -- the newest ts in the bucket
  PRIMARY KEY (project, hour)
);
-- Serves the window read (`hour >= ? AND hour < ? GROUP BY project`, covering)
-- and the retention id read (`hour < ? ORDER BY hour`).
CREATE INDEX IF NOT EXISTS idx_cost_project_hourly_hour ON cost_project_hourly(hour, project, usd, max_ts);

-- no-index: cost_fold_mark one row per fold, read by its PRIMARY KEY
-- The fold watermark: the highest cost_rows rowid already summed into
-- cost_project_hourly. One row ('progress.cost'); it does not grow, so it has
-- no retention rule.
CREATE TABLE IF NOT EXISTS cost_fold_mark (
  name TEXT PRIMARY KEY,
  last_rowid INTEGER NOT NULL
);
INSERT OR IGNORE INTO cost_fold_mark (name, last_rowid) VALUES ('progress.cost', 0);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.cost_project_hourly.days','400','BH-7164: days an hourly cost bucket is kept (0 = off). A cache of cost_rows, which keeps every row. Keep it at 31 or more: GET /api/progress/stamps reads up to 30 days of buckets.','seed','2026-10-16T00:00:00Z');
