-- ── BH-7300 (slice C0): docker_pool_leases ──────────────────────────────────
-- One row per docker-pool claim: a named box (a local Docker host, not a Fly
-- machine) took one queued target='fly' build_queue row and must beat before
-- lease_until. status = active | done | released | expired | killed. At most
-- one `active` row per (project, ticket_key). claimed_at is the build_queue
-- row's claimed_at of the same claim, so a lease only ever touches the exact
-- claim it was made for. Routes: worker/jobs/src/routes/docker-pool.js.
-- Note: docs/notes/2026-10-17-BH-7300-docker-pool-lease.md.
--
-- INDEXES. Each query and the index that serves it:
--   claim CAS   SELECT COUNT(*) ... WHERE box=?3 AND status='active'
--         idx_docker_pool_leases_box (box, status).
--   heartbeat, release, claim lease insert/orphan end
--         WHERE project=?1 AND ticket_key=?2 AND status='active'
--         uq_docker_pool_leases_live (project, ticket_key) WHERE status='active'.
--   sweep select  WHERE status='active' AND lease_until < ?1 ORDER BY lease_until
--         idx_docker_pool_leases_due (status, lease_until).
--   sweep batch   WHERE id IN (json_each) — the INTEGER PRIMARY KEY.
--   retention id read  WHERE status<>'active' AND ended_at < ?1 ORDER BY ended_at
--         idx_docker_pool_leases_ended (ended_at).
--
-- RETENTION (src/routes/retention.js rule docker_pool_leases.ended, the hourly
-- bin/d1-retention.sh lane). An ended lease is coordination state with no
-- money in it; the build history stays in build_queue and the jobs ledger.
-- Ended rows older than retention.docker_pool_leases.days (30) are deleted.
-- retention.dry_run (seed 1) applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS docker_pool_leases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  box TEXT NOT NULL,
  status TEXT NOT NULL,
  claimed_at TEXT NOT NULL,
  heartbeat_at TEXT NOT NULL,
  lease_until TEXT NOT NULL,
  ended_at TEXT,
  end_reason TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_docker_pool_leases_live ON docker_pool_leases(project, ticket_key) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_docker_pool_leases_box ON docker_pool_leases(box, status);
CREATE INDEX IF NOT EXISTS idx_docker_pool_leases_due ON docker_pool_leases(status, lease_until);
CREATE INDEX IF NOT EXISTS idx_docker_pool_leases_ended ON docker_pool_leases(ended_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('docker_pool.max_concurrent','0','BH-7300: docker-pool builds one box may hold at once (0..64; 0 = off, the default). A row docker_pool.max_concurrent.<box> wins over this one. No row or a value that is not an integer in range is 0.','seed','2026-10-17T10:04:00Z'),
  ('docker_pool.kill','0','BH-7300: 1 refuses every docker-pool claim, and every heartbeat ends its lease and puts the row back on the queue. 0 = normal.','seed','2026-10-17T10:04:00Z'),
  ('docker_pool.lease_s','300','BH-7300: seconds a docker-pool lease lives after a claim or a heartbeat (60..3600; the code default is 300). The jobs-watchdog */5 tick requeues a lease past this time.','seed','2026-10-17T10:04:00Z'),
  ('retention.docker_pool_leases.days','30','BH-7300: days an ended docker-pool lease row is kept (0 = off)','seed','2026-10-17T10:04:00Z');
