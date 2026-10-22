-- ── BH-7934: onboarding_runs, onboarding_steps ──────────────────────────────
-- One onboarding_runs row per onboarding of a project (the console's "add a
-- project" form), and one onboarding_steps row per station of that run, ord
-- 1..7: register, prompt, label (tracker when the tracker is not
-- github-issues), box, clone, smoke, ready. The writer of both today is
-- POST /api/onboarding/runs (src/routes/onboarding.js, BH-7934.0); the readers
-- are GET /api/onboarding/runs/:id, and next the runner lane (BH-7934.2), the
-- retry and cancel actions (BH-7934.3) and the tracker check (BH-7936).
--
-- INDEXES. Each query and the index that serves it:
--   run read               WHERE id = ?1
--         the primary key (id): one seek.
--   steps read             WHERE run_id = ?1 ORDER BY ord
--         idx_onboarding_steps_run_ord (run_id, ord): a range, no sort.
--   queued poll            WHERE state = 'queued' ORDER BY updated_at LIMIT 1
--         idx_onboarding_runs_state_updated (state, updated_at).
--   project list           WHERE project = ?1 ORDER BY created_at DESC LIMIT ?2
--         idx_onboarding_runs_project_created (project, created_at).
--   retention id read      WHERE state IN ('done','failed','cancelled')
--                          AND updated_at < ?1 ORDER BY updated_at LIMIT ?2
--         idx_onboarding_runs_state_updated (state, updated_at).
--   retention child delete WHERE run_id IN (...)
--         idx_onboarding_steps_run_ord (its run_id prefix).
-- test/onboarding-explain.bh-7934.test.js proves each one on 5,000 runs and
-- 35,000 steps.
--
-- RETENTION. A finished run (done, failed, cancelled) and its steps keep value
-- for onboarding_runs_retention_days (30) after their last update. BH-7934.2
-- adds the retention rule that reads that row and deletes the older runs and
-- their steps (no money, no history). Until then a run adds 1 + 7 rows.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS onboarding_runs (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  repo TEXT NOT NULL,
  inputs_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('queued','running','failed','done','cancelled')),
  station TEXT,
  created_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_onboarding_runs_state_updated ON onboarding_runs(state, updated_at);
CREATE INDEX IF NOT EXISTS idx_onboarding_runs_project_created ON onboarding_runs(project, created_at);
CREATE TABLE IF NOT EXISTS onboarding_steps (
  run_id TEXT NOT NULL,
  station TEXT NOT NULL,
  ord INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('queued','running','done','failed','skipped')),
  started_at TEXT,
  finished_at TEXT,
  log_excerpt TEXT,
  retries INTEGER NOT NULL DEFAULT 0,
  error_code TEXT,
  PRIMARY KEY (run_id, station)
);
CREATE INDEX IF NOT EXISTS idx_onboarding_steps_run_ord ON onboarding_steps(run_id, ord);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding_runs_retention_days','30','BH-7934: days a finished onboarding run and its steps are kept; BH-7934.2 adds the retention rule that reads it','seed','2026-10-22T01:14:00Z');
