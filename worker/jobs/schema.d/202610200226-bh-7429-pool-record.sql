-- ── BH-7429 (BH-6896 S2): pool_record_files ─────────────────────────────────
-- The build record of one finished pool machine, kept OFF the machine: the
-- full RESULT, the build-dir files the hub reap relays and the failovers.log
-- tail. fly/builder-runner.sh posts it once per job (bin/lib/pool-record.sh
-- pool_record_put); the hub reap in bin/fly-pool.sh reads it instead of one
-- `ssh console` per file, and stamps it. One row per file, because D1 caps a
-- row at 2 MB. A record is the rows that share (project, ticket_key, machine,
-- build_dir). Rows are a transport copy: the hub build dir is the record of
-- the build. Routes: worker/jobs/src/routes/pool-records.js.
-- Note: docs/notes/2026-10-19-BH-7429-pool-record.md.
--
-- INDEXES. Each query and the index that serves it:
--   POST clear   DELETE ... WHERE project=?1 AND ticket_key=?2 AND machine=?3
--         AND build_dir=?4 AND reaped_at IS NULL
--         uq_pool_record_files_file prefix.
--   POST insert  ON CONFLICT(project, ticket_key, machine, build_dir, name),
--         and its NOT EXISTS reaped guard on the same four columns
--         uq_pool_record_files_file.
--   GET step 1   WHERE project=?1 AND ticket_key=?2 AND machine=?3
--         AND name='RESULT' AND posted_at>=?4 AND reaped_at IS NULL
--         ORDER BY posted_at DESC LIMIT 1
--         idx_pool_record_files_result (project, ticket_key, machine, name, posted_at).
--   GET step 2   WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND build_dir=?4
--         ORDER BY name   uq_pool_record_files_file.
--   reaped stamp UPDATE ... WHERE the same four columns AND reaped_at IS NULL
--         uq_pool_record_files_file prefix.
--   retention, read rows  WHERE reaped_at IS NOT NULL AND reaped_at < ?1
--         ORDER BY reaped_at  idx_pool_record_files_reaped (partial).
--   retention, unread rows  WHERE reaped_at IS NULL AND posted_at < ?1
--         ORDER BY posted_at  idx_pool_record_files_unread (partial).
--   retention delete  WHERE id IN (json_each) — the INTEGER PRIMARY KEY.
--
-- RETENTION (src/routes/retention.js rules pool_record_files.reaped and
-- pool_record_files.unread, the hourly bin/d1-retention.sh lane). A row the
-- hub read is deleted retention.pool_record_files.reaped_days (1) after the
-- read. A row nobody read (the hub took the ssh path, or never reaped the
-- machine) is deleted retention.pool_record_files.unread_days (3) after it was
-- posted. No money and no history: delete, not archive. retention.dry_run
-- (seed 1) applies.
--
-- ROLLOUT. lane.fly-pool.project-6-os.pool_record_read = 1: project-6-os goes
-- first. Every other project reads the knob default (0) and stays on the ssh
-- path until an operator sets its row.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pool_record_files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  machine TEXT NOT NULL,
  build_dir TEXT NOT NULL,
  name TEXT NOT NULL,
  body TEXT,
  bytes INTEGER NOT NULL,
  skipped INTEGER NOT NULL DEFAULT 0,
  posted_at TEXT NOT NULL,
  reaped_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_pool_record_files_file ON pool_record_files(project, ticket_key, machine, build_dir, name);
CREATE INDEX IF NOT EXISTS idx_pool_record_files_result ON pool_record_files(project, ticket_key, machine, name, posted_at);
CREATE INDEX IF NOT EXISTS idx_pool_record_files_reaped ON pool_record_files(reaped_at) WHERE reaped_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pool_record_files_unread ON pool_record_files(posted_at) WHERE reaped_at IS NULL;
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.pool_record_files.reaped_days','1','BH-7429: days a pool build-record row is kept after the hub reap read it (0 = off).','seed','2026-10-19T15:45:00Z'),
  ('retention.pool_record_files.unread_days','3','BH-7429: days a pool build-record row nobody read is kept after it was posted (0 = off).','seed','2026-10-19T15:45:00Z'),
  ('lane.fly-pool.project-6-os.pool_record_read','1','BH-7429: project-6-os posts and reads pool build records first; every other project stays on the ssh pull.','seed','2026-10-19T15:45:00Z');
