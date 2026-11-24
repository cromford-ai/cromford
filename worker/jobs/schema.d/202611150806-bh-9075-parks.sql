-- ── BH-9075 (BH-9067.3): parks, one row per parked candidate ───────────────
-- A park is a candidate the blocked-resolver must look at: a pool death or
-- deferral (source queue) or a conductor BLOCKED_HUMAN / RED_TWICE (source
-- conductor). One row per (project, ck). The writers are bin/lib/parks-write.sh
-- (fly-pool, merge-conductor, blocked-resolver, br-backfill) through
-- PUT /api/parks. The reader is bin/lib/br/opt/parks.sh through
-- GET /api/parks/changed, which pages by (updated_at, ck). The route is
-- src/routes/parks.js. updated_at and parked_at are writer epoch seconds.
-- Last writer wins, guarded by updated_at: an older write never replaces a
-- newer one (WHERE excluded.updated_at >= parks.updated_at).
--
-- INDEXES. Each read and the index that serves it:
--   upsert by (project, ck)               PK autoindex sqlite_autoindex_parks_1
--   changed page  WHERE project=? AND updated_at>=? ORDER BY updated_at, ck
--                                         idx_parks_project_updated (ck as the
--                                         third column removes the temp b-tree)
--   hotfix list   WHERE state='hotfix' AND project=? ORDER BY updated_at
--                                         idx_parks_state_updated (state=?)
--   prune ids     WHERE state='done' AND updated_at<? ORDER BY updated_at LIMIT ?
--                                         idx_parks_state_updated
--
-- RETENTION. The table has its own prune: POST /api/parks/prune deletes done
-- rows whose updated_at is older than parks.retention_days, at most
-- parks.retention_batch per run, dry run first (parks.prune_dry_run), one
-- retention_runs row per run. A parked or hotfix row is live state and is
-- never deleted. The resolver calls the prune daily (BR_PARKS_PRUNE_EVERY_S).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS parks (
  project TEXT NOT NULL,
  ck TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '-',          -- queue | conductor | '-'
  state TEXT NOT NULL CHECK (state IN ('parked','hotfix','done')),
  head TEXT NOT NULL DEFAULT '-',
  reason TEXT NOT NULL DEFAULT '-',
  url TEXT NOT NULL DEFAULT '-',
  rec TEXT NOT NULL DEFAULT '-',
  ticket TEXT NOT NULL DEFAULT '-',
  updated_at INTEGER NOT NULL,               -- writer epoch seconds
  writer TEXT NOT NULL DEFAULT '-',          -- fly-pool | merge-conductor | blocked-resolver | br-backfill
  parked_at INTEGER,                         -- the 8th candidate field (conductor since); NULL = unknown
  PRIMARY KEY (project, ck)
);
CREATE INDEX IF NOT EXISTS idx_parks_project_updated ON parks(project, updated_at, ck);
CREATE INDEX IF NOT EXISTS idx_parks_state_updated ON parks(state, updated_at);
-- no-retention: parks own prune: POST /api/parks/prune deletes done rows older than parks.retention_days (d1-retention-coverage C3 forbids a retention.d rule for parks)

-- Knobs. Every reader is src/routes/parks.js; each note names the code fallback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.retention_days','30','BH-9075: days a done parks row is kept. Reader: src/routes/parks.js prune (0 = rule off, 0-3650, fallback 30).','seed','2026-11-15T08:06:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.retention_batch','500','BH-9075: most done rows one prune run deletes; a full batch sets backlog. Reader: src/routes/parks.js prune (1-5000, fallback 500).','seed','2026-11-15T08:06:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.prune_dry_run','1','BH-9075: 1 = the parks prune only counts. Set 0 after one dry report. Reader: src/routes/parks.js prune (0-1, fallback 1).','seed','2026-11-15T08:06:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.put_max_rows','100','BH-9075: most rows one PUT /api/parks accepts. Reader: src/routes/parks.js PUT (1-1000, fallback 100).','seed','2026-11-15T08:06:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.changed_max_limit','1000','BH-9075: most rows one GET /api/parks/changed page returns, and the default limit. Reader: src/routes/parks.js changed (1-10000, fallback 1000).','seed','2026-11-15T08:06:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('parks.hotfix_max','50','BH-9075: most hotfix rows GET /api/parks/changed?hotfix=1 returns. Reader: src/routes/parks.js changed (1-1000, fallback 50).','seed','2026-11-15T08:06:00Z');
