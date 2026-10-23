-- ── BH-7969 (BH-7940.0): prompt_versions and prompt_heads ──────────────────
-- A prompt override is an immutable prompt_versions row. One prompt_heads row
-- per (scope, project, kind) points at the version that is in use. A save
-- inserts version n+1 and moves the head in one D1 batch; no route updates or
-- deletes a body. Fleet rows store project = '' (never NULL), so the unique
-- indexes hold. Routes: worker/jobs/src/routes/prompts.js through
-- src/lib/prompt-store.js. Hub reader: bin/prompt-resolve.sh. docs/PROMPTS.md.
--
-- INDEXES. Each query and the index that serves it:
--   list  prompt_heads WHERE scope=? AND project=?: prompt_heads_key prefix
--         (scope, project); JOIN prompt_versions ON v.id = h.version_id:
--         the integer primary key.
--   read  WHERE scope=? AND project=? AND kind=? AND version=?:
--         prompt_versions_key.
--   save  MAX(version) WHERE scope=? AND project=? AND kind=?, and the head
--         upsert's ORDER BY version DESC LIMIT 1: prompt_versions_key prefix;
--         ON CONFLICT(scope, project, kind): prompt_heads_key; the version
--         read by id after the save: the integer primary key.
--
-- RETENTION is owned by BH-7940.4 (a d1-retention rule). The window row
-- prompts.retention.keep_versions is seeded here; nothing reads it yet. These
-- are history rows: the rule archives, it never silently deletes. prompt_heads
-- is bounded at (1 + projects) x 7 rows.
-- D1 is SQLite, not Supabase: RLS does not apply; the worker bearer guards
-- /api/*. Only IF NOT EXISTS and INSERT OR IGNORE, so a re-apply through
-- bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS prompt_versions (
  id INTEGER PRIMARY KEY,
  scope TEXT NOT NULL CHECK(scope IN ('fleet','project')),
  project TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  version INTEGER NOT NULL,
  body TEXT NOT NULL,
  author TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS prompt_versions_key ON prompt_versions(scope, project, kind, version);
CREATE TABLE IF NOT EXISTS prompt_heads (
  scope TEXT NOT NULL CHECK(scope IN ('fleet','project')),
  project TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  set_by TEXT NOT NULL,
  set_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS prompt_heads_key ON prompt_heads(scope, project, kind);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('prompts.retention.keep_versions','200','BH-7940: prompt versions kept per (scope, project, kind) before the BH-7940.4 retention rule archives the older ones.','seed','2026-10-22T12:16:00Z'),
  ('prompts.body_max_bytes','262144','BH-7940: the largest prompt body a save accepts, in UTF-8 bytes. A larger body is a 413.','seed','2026-10-22T12:16:00Z');
