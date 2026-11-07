-- BH-9076 (slice 5 of BH-9067): the D1 statement counter. Additive only.
--
-- One row per (hour, sql_hash): `hour` is the UTC hour 'YYYY-MM-DDTHH',
-- `sql_hash` the FNV-1a 64 hash of the normalized statement text
-- (worker/jobs/src/lib/stmt-stats.js), `calls` and `rows_read` the SAMPLED
-- counts (scale by 100 / d1.stmt_stats_sample_pct for an estimate). Written by
-- one batch of upserts after each sampled request; read by GET
-- /api/d1/stmt-stats/top (worker/jobs/src/routes/d1-stmt-stats.js).
--
-- Indexes, one per read:
--   flush upsert   ON CONFLICT (hour, sql_hash)              the PRIMARY KEY
--   GET /top       `hour >= ? GROUP BY sql_hash`             idx_d1_stmt_stats_hour_calls (range on hour)
--   retention ids  `hour < ? ORDER BY hour`                  the PRIMARY KEY (prefix hour)
-- Retention: rule stmt_stats.age (routes/retention.d/bh-9076-d1-stmt-stats.js)
-- deletes hours older than retention.d1_stmt_stats.days (14). The rows are
-- sampled stats, not history: nothing reads them after the window.
CREATE TABLE IF NOT EXISTS d1_stmt_stats (
  hour TEXT NOT NULL,
  sql_hash TEXT NOT NULL,
  sql_text TEXT NOT NULL,
  calls INTEGER NOT NULL DEFAULT 0,
  rows_read INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, sql_hash)
);
CREATE INDEX IF NOT EXISTS idx_d1_stmt_stats_hour_calls ON d1_stmt_stats(hour, calls);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('d1.stmt_stats_sample_pct','1','BH-9076: percent of worker requests whose D1 statements are counted into d1_stmt_stats (0..100; 0 = off, 100 = every request). A value that is not an integer in range runs as 1.','seed','2026-11-07T00:00:00Z'),
  ('d1.stmt_stats_refresh_s','300','BH-9076: seconds an isolate keeps the d1.stmt_stats_* knobs before it reads them again (10..3600).','seed','2026-11-07T00:00:00Z'),
  ('d1.stmt_stats_sql_max_chars','500','BH-9076: characters of normalized SQL kept in d1_stmt_stats.sql_text (50..4000).','seed','2026-11-07T00:00:00Z'),
  ('d1.stmt_stats_max_keys','500','BH-9076: distinct (hour, statement) keys an isolate holds before new statements count under the hash overflow (10..10000).','seed','2026-11-07T00:00:00Z'),
  ('d1.stmt_stats_top_max','100','BH-9076: the largest n GET /api/d1/stmt-stats/top accepts (1..1000); a larger n is 400.','seed','2026-11-07T00:00:00Z'),
  ('d1.stmt_stats_hours_max','336','BH-9076: the largest hours GET /api/d1/stmt-stats/top accepts (1..8760); a larger value is 400. 336 = the 14-day retention window.','seed','2026-11-07T00:00:00Z'),
  ('retention.d1_stmt_stats.days','14','BH-9076: days a d1_stmt_stats hour row is kept; the stmt_stats.age retention rule deletes older hours (0 = off).','seed','2026-11-07T00:00:00Z');
