-- ── BH-7261 (BH-7244.3): the PM agent's weekly grooming brief ──────────────
-- bin/pm-groom.sh writes one brief per (project, ISO week) and its proposed
-- idea moves. Mission Control (/roadmap/<p>?view=brief) shows them, and an
-- approve moves the roadmap idea (roadmap_ideas.lane) through a CAS on
-- from_col. It never files a ticket, adds a label or starts a build.
--   pm_briefs  one row per (project, week). The row IS the claim for the one
--              model call of the week: status claimed | ready | failed
--              (checked in JS). claimed and failed are billed; only a person
--              (pm-groom.sh --force) re-claims them. body is JSON:
--              {summary, stale:[{idea_id,title,lane,age_days}], stale_partial,
--               scores:[{idea_id,score,why}], now:[{idea_id,title,reason,
--               evidence}], next_wave:[idea_id], snapshot_hash}.
--              sent_mc=1 is set in the same UPDATE that makes the row ready;
--              sent_tg=1 only after bin/archie-tg-send.sh answered rc 0.
--   pm_moves   one proposed move of one idea. from_col and to_col are
--              roadmap_ideas lanes only (ideas | next | discarded). status =
--              proposed | approved | rejected | stale. evidence is a JSON
--              array of evidence ids. A Now proposal is text in the body, never
--              a row.
-- Writer and reader: src/routes/pm-brief.js. Note:
-- docs/notes/2026-10-20-BH-7261-pm-groom.md.
--
-- INDEXES. Each query and the index that serves it:
--   claim, read by week   WHERE project=?1 AND week=?2
--         ux_pm_briefs_project_week (project, week), also the ON CONFLICT target
--   newest week, weeks    WHERE project=?1 ORDER BY week DESC LIMIT n
--         ux_pm_briefs_project_week
--   moves of a brief      WHERE brief_id=?1 (and status='proposed' for the
--         "any left" EXISTS)   idx_pm_moves_brief (brief_id, status)
--   move by id            the primary key
--   retention ids         WHERE created_at < ?1 ORDER BY created_at
--         idx_pm_briefs_created, idx_pm_moves_created
--
-- RETENTION (src/routes/retention.js, the hourly bin/d1-retention.sh lane):
-- pm_briefs.age and pm_moves.age copy a row to the archive D1 before the
-- delete, after pm.brief_retention_days (365). With the archive unbound they
-- delete nothing. retention.dry_run (seed 1) applies.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pm_briefs (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  week TEXT NOT NULL,
  status TEXT NOT NULL,
  input_fp TEXT,
  model TEXT,
  body TEXT,
  sent_mc INTEGER NOT NULL DEFAULT 0,
  sent_tg INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_pm_briefs_project_week ON pm_briefs(project, week);
CREATE INDEX IF NOT EXISTS idx_pm_briefs_created ON pm_briefs(created_at);
CREATE TABLE IF NOT EXISTS pm_moves (
  id TEXT PRIMARY KEY,
  brief_id TEXT NOT NULL,
  project TEXT NOT NULL,
  idea_id TEXT NOT NULL,
  from_col TEXT NOT NULL,
  to_col TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'proposed',
  reason TEXT,
  evidence TEXT,
  decided_by TEXT,
  decided_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pm_moves_brief ON pm_moves(brief_id, status);
CREATE INDEX IF NOT EXISTS idx_pm_moves_created ON pm_moves(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pm.stale_days','30','BH-7261: days with no change after which pm-groom flags a roadmap idea as stale (1..365)','seed','2026-10-20T00:02:00Z'),
  ('pm.backlog_limit','1000','BH-7261: roadmap ideas pm-groom reads per lane (1..1000); a longer lane sets stale_partial','seed','2026-10-20T00:02:00Z'),
  ('pm.moves_max','50','BH-7261: moves one PM brief may hold (1..200); pm-groom drops the rest, the worker refuses more','seed','2026-10-20T00:02:00Z'),
  ('pm.now_max','10','BH-7261: Now entries one PM brief keeps (1..50)','seed','2026-10-20T00:02:00Z'),
  ('pm.next_wave_max','10','BH-7261: next_wave idea ids one PM brief keeps (1..50)','seed','2026-10-20T00:02:00Z'),
  ('pm.weeks_shown','12','BH-7261: past weeks the brief view lists (1..104)','seed','2026-10-20T00:02:00Z'),
  ('pm.brief_retention_days','365','BH-7261: days a PM brief and its moves stay hot before they move to the archive (0 = off)','seed','2026-10-20T00:02:00Z'),
  ('pm.reason_max_chars','500','BH-7261: characters of one move or Now reason (1..2000); pm-groom cuts to it, the worker refuses more','seed','2026-10-20T00:02:00Z'),
  ('pm.evidence_max','20','BH-7261: evidence ids one PM move may cite (1..100); the worker refuses more','seed','2026-10-20T00:02:00Z'),
  ('pm.body_max_chars','65536','BH-7261: characters of one PM brief body as JSON (1024..1048576); the worker refuses more','seed','2026-10-20T00:02:00Z'),
  ('pm.error_max_chars','500','BH-7261: characters of the error text of a failed PM brief (1..2000)','seed','2026-10-20T00:02:00Z'),
  ('pm.summary_max_chars','1000','BH-7261: characters of the PM brief summary pm-groom keeps (1..10000)','seed','2026-10-20T00:02:00Z'),
  ('pm.score_why_max_chars','200','BH-7261: characters of one score reason pm-groom keeps (1..2000)','seed','2026-10-20T00:02:00Z'),
  ('pm.note_max_chars','300','BH-7261: characters of an idea note pm-groom puts in the prompt (1..5000)','seed','2026-10-20T00:02:00Z'),
  ('pm.scores_max','200','BH-7261: score entries one PM brief keeps, highest score first (0..1000); more sets scores_partial','seed','2026-10-20T00:02:00Z'),
  ('pm.stale_max','200','BH-7261: stale entries one PM brief body keeps, oldest first (0..1000); more sets stale_partial','seed','2026-10-20T00:02:00Z');
