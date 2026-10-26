-- ── BH-8317 (MKF-2): project_secret_names ──────────────────────────────────────
-- The manifest of a project's build secrets: one row per (project, NAME) that
-- bin/project-secrets.sh staged into Fly app secrets. NAMES ONLY. The value
-- lives only in the Fly apps (write-only through the Fly API); no column here
-- can hold it, and src/routes/project-secrets.js refuses a body that carries one.
-- Note: docs/notes/2026-10-25-BH-8317-secret-store.md.
--
-- apps     JSON array of Fly app names (1..n, deduped, order kept).
-- need     required | optional. bin/project-secrets.sh verify fails only on a
--          missing required name.
-- set_at   stamped only after every app took the value (PUT stamp:true);
--          NULL = intent recorded, delivery not proved.
-- digest   JSON {app: digest} read back from `fly secrets list`.
--
-- INDEXES. Each query and the index that serves it:
--   GET list       WHERE project=?1 ORDER BY name LIMIT n
--                  the PRIMARY KEY (sqlite_autoindex_project_secret_names_1).
--   GET pending    WHERE project=?1 AND set_at IS NULL
--                  ix_project_secret_names_project_set_at.
--   PUT upsert, PUT/DELETE row read, DELETE   WHERE project=?1 AND name=?2: the PK.
--
-- RETENTION. A row lives while the secret exists. `unset` deletes the row, and
-- the route writes one config_changes row (kind project_secret) in the same
-- batch; config_changes is append-only and never deleted. The table holds tens
-- of rows per project and does not grow with traffic, so it has no sweep.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS project_secret_names (
  project TEXT NOT NULL,
  name TEXT NOT NULL,
  apps TEXT NOT NULL,
  need TEXT NOT NULL DEFAULT 'required' CHECK (need IN ('required','optional')),
  set_at TEXT,
  set_by TEXT NOT NULL,
  digest TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, name)
);
CREATE INDEX IF NOT EXISTS ix_project_secret_names_project_set_at ON project_secret_names(project, set_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('project_secrets.list_limit','500','BH-8317: the most rows GET /api/project-secrets/names answers for one project (1..5000; any other value answers 500). Code fallback 500 in worker/jobs/src/routes/project-secrets.js','seed','2026-10-25T22:58:00Z'),
  ('project_secrets.fly_timeout_s','120','BH-8317: seconds bin/project-secrets.sh gives each flyctl call (1..3600; any other value uses 120). Code fallback 120 in bin/project-secrets.sh','seed','2026-10-25T22:58:00Z');
