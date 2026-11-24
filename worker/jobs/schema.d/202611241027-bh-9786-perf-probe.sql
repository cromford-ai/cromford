-- ── BH-9786: the daily perf probe's result rows ────────────────────────────
-- bin/perf-probe.sh (a hub cron lane, 06:17Z) loads each route of a project
-- row in catalog/perf-probe.d/ and writes one row per route per day through
-- POST /api/perf-probe/results (src/routes/perf-probe.js). The natural key is
-- (project, route, day, kind, run_key): a rerun on the same day replaces the
-- row, never duplicates it. kind 'daily' is the cron run; 'post-deploy' is
-- reserved for a later child of BH-9786.
-- Note: docs/notes/2026-11-17-BH-9786-perf-probe.md.
--
-- INDEXES. Each read and the index that serves it:
--   upsert / one route's row       WHERE project=? AND route=? AND day=?
--                                   (AND kind=? AND run_key=?)
--                                   uq_perf_probe_results
--   one project's day, by route    WHERE project=? AND day=? AND kind=?
--                                   ORDER BY route
--                                   idx_perf_probe_results_pday
--   retention ids                  WHERE day < ? ORDER BY day
--                                   idx_perf_probe_results_day
--
-- EXPLAIN QUERY PLAN at 100,000 seeded rows (worker/jobs/test/
-- perf-probe.bh-9786.test.js, case W6):
--   one route's row     SEARCH perf_probe_results USING INDEX
--                       uq_perf_probe_results (project=? AND route=? AND day=?)
--   one project's day   SEARCH perf_probe_results USING INDEX
--                       idx_perf_probe_results_pday (project=? AND day=? AND kind=?)
--                       USE TEMP B-TREE FOR ORDER BY
--   retention ids       SEARCH perf_probe_results USING COVERING INDEX
--                       idx_perf_probe_results_day (day<?)
--
-- RETENTION (retention.d/bh-9786-perf-probe.js, the hourly bin/d1-retention.sh
-- lane; retention.dry_run applies): a row whose day is older than
-- perf_probe.retention_days (90) is deleted. The rows are operational timing
-- samples: no money or history value past the window. 12-month size without
-- retention: about 300k rows; with it, about 75k live rows.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS perf_probe_results (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  route TEXT NOT NULL,
  day TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('daily','post-deploy')),
  run_key TEXT NOT NULL,
  ttfb_ms INTEGER,
  total_ms INTEGER,
  bytes INTEGER,
  status INTEGER,
  over_budget INTEGER NOT NULL DEFAULT 0,
  outcome TEXT,
  loads INTEGER,
  breaks INTEGER,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_perf_probe_results ON perf_probe_results(project, route, day, kind, run_key);
CREATE INDEX IF NOT EXISTS idx_perf_probe_results_pday ON perf_probe_results(project, day, kind);
CREATE INDEX IF NOT EXISTS idx_perf_probe_results_day ON perf_probe_results(day);

-- Knobs. Readers: retention.d/bh-9786-perf-probe.js (retention_days, 0 = rule
-- off) and src/routes/perf-probe.js (rows_max).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('perf_probe.retention_days','90','BH-9786: days a perf_probe_results row is kept, by its day. Reader: retention.d/bh-9786-perf-probe.js (0 = rule off, fallback 90).','seed','2026-11-17T19:00:00Z'),
  ('perf_probe.rows_max','500','BH-9786: most rows one POST /api/perf-probe/results may carry; more rows are a 400 {error:"rows"}. Reader: src/routes/perf-probe.js (1-100000, fallback 500).','seed','2026-11-17T19:00:00Z');
