-- ── BH-7348 (BH-7300 slice C2): docker_pool_results ─────────────────────────
-- One row per finished docker-pool claim. The docker host reaps its own build
-- dir after the container exits (bin/lib/docker-pool-reap.sh): it pushes the
-- cost rows first, then posts this summary row. The hub reads it through
-- POST /api/docker-pool/results/reap (bin/jobs-watchdog.sh). Natural key
-- (project, ticket_key, claimed_at): claimed_at is the lease's claim, so a
-- requeued and re-claimed ticket gets a new row. No money column: the money
-- stays in cost_rows under cost_box. Routes:
-- worker/jobs/src/routes/docker-pool-results.js.
-- Note: docs/notes/2026-10-17-BH-7348-docker-pool-results.md.
--
-- INDEXES. Each query and the index that serves it:
--   result upsert  ON CONFLICT(project, ticket_key, claimed_at)
--         uq_docker_pool_results_claim (project, ticket_key, claimed_at).
--   result lease read  SELECT ... FROM docker_pool_leases WHERE project=?1
--         AND ticket_key=?2 AND box=?3 ORDER BY id DESC LIMIT 1
--         idx_docker_pool_leases_key (ticket_key, box); the rowid id ends
--         every index, so it also serves ORDER BY id. Two columns, not
--         three: with project in it the planner took it over
--         uq_docker_pool_leases_live for C0's heartbeat.
--   reap id read  WHERE reaped_at IS NULL ORDER BY posted_at LIMIT ?1
--         idx_docker_pool_results_unread (posted_at) WHERE reaped_at IS NULL.
--   reap stamp    WHERE id IN (json_each) — the INTEGER PRIMARY KEY.
--   retention id read  WHERE reaped_at IS NOT NULL AND posted_at < ?1
--         ORDER BY posted_at  idx_docker_pool_results_posted (posted_at).
--
-- RETENTION (src/routes/retention.js rule docker_pool_results.age, the hourly
-- bin/d1-retention.sh lane). A read row older than
-- retention.docker_pool_results.days (30) is deleted. An unread row is never
-- a candidate. retention.dry_run (seed 1) applies.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS docker_pool_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  claimed_at TEXT NOT NULL,
  box TEXT NOT NULL,
  cost_box TEXT NOT NULL,
  auth_account TEXT NOT NULL,
  job_id TEXT,
  result TEXT NOT NULL,
  pr_url TEXT,
  tier INTEGER,
  cost_rows INTEGER NOT NULL,
  unpriced_rows INTEGER NOT NULL,
  cost_verified INTEGER NOT NULL,
  posted_at TEXT NOT NULL,
  reaped_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_docker_pool_results_claim ON docker_pool_results(project, ticket_key, claimed_at);
CREATE INDEX IF NOT EXISTS idx_docker_pool_results_unread ON docker_pool_results(posted_at) WHERE reaped_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_docker_pool_results_posted ON docker_pool_results(posted_at);
CREATE INDEX IF NOT EXISTS idx_docker_pool_leases_key ON docker_pool_leases(ticket_key, box);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.docker_pool_results.days','30','BH-7348: days a docker-pool result row the hub already read is kept (0 = off). An unread row is never deleted.','seed','2026-10-17T23:27:00Z');
