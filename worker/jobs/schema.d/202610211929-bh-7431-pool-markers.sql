-- ── BH-7431 (BH-6896 S4): pool_markers ─────────────────────────────────────
-- The pool's once-markers and wait clocks as rows, next to the files in
-- state/pool/<p>/ that stay the fail-open copy: <key>.terminal-noted,
-- .terminal-alerted, .after-since, .after-released, .after-loop and
-- .defer-to-human (marker `cap-wait`; the file keeps its legacy name). One row
-- per (project, ticket_key, marker). value is the file's content byte for byte
-- (`<blocker>\t<epoch>`, `<blocker>\t<n>\t<epoch>`, `<blocker>` or empty).
-- Routes: worker/jobs/src/routes/pool-markers.js (PUT, PATCH) and the GET in
-- worker/jobs/src/routes/pool-state.js. Shell side: bin/lib/pool-state-rows.sh.
--
-- INDEXES. Each query and the index that serves it:
--   GET  WHERE project=?1 ORDER BY updated_at DESC, ticket_key, marker LIMIT 2001
--         idx_pool_markers_project_updated (project, updated_at).
--   PUT upsert ON CONFLICT(project, ticket_key, marker), PATCH delete by full
--         key  the PRIMARY KEY (project, ticket_key, marker).
--   retention id read  WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2
--         idx_pool_markers_updated (updated_at).
--   retention delete  WHERE rowid IN (json_each) — the rowid.
--
-- RETENTION (src/routes/retention.js rule pool_markers.age, the hourly
-- bin/d1-retention.sh lane). A row older than retention.pool_markers.days (30)
-- is deleted: the after-gate ceiling is 6 h and the cap window 24 h, so a
-- 30-day-old marker gates nothing. retention.dry_run (seed 1) applies. No money
-- in these rows.
-- D1 is SQLite, not Supabase: RLS does not apply; the worker bearer guards
-- /api/*. Only IF NOT EXISTS and INSERT OR IGNORE, so a re-apply through
-- bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pool_markers (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  marker TEXT NOT NULL,
  value TEXT,
  box TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key, marker)
);
CREATE INDEX IF NOT EXISTS idx_pool_markers_project_updated ON pool_markers(project, updated_at);
CREATE INDEX IF NOT EXISTS idx_pool_markers_updated ON pool_markers(updated_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.pool_markers.days','30','BH-7431: days a pool marker row (terminal-noted, terminal-alerted, after-*, cap-wait) is kept (0 = off). The longest window a marker gates is 24 h.','seed','2026-10-19T15:30:00Z');
