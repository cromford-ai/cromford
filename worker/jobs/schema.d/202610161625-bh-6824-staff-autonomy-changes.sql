-- ── BH-6824 (Staff in Mission Control 3/4): the autonomy audit ───────────────
-- staff_autonomy_changes: one row per REAL change of a staff agent's level
-- (kind 'autonomy', class NULL) or of one staff class's state (kind
-- 'delegation'). Written only by POST /api/staff/agents/autonomy and POST
-- /api/staff/classes/delegation (src/routes/staff.js), as an
-- INSERT ... SELECT ... WHERE changes() = 1 in the SAME D1 batch as the state
-- UPDATE: a no-op or a refused change writes no row, and a state change never
-- lands without its row. reason is NULL only for an API caller that sent none;
-- the console's coord proxy refuses a blank reason before the worker.
--
-- INDEXES, one per query:
--   GET /api/staff/autonomy (src/routes/staff-autonomy.js)
--     WHERE agent = ?1 ORDER BY id DESC LIMIT ?2   -> idx_staff_autonomy_changes_agent_id
--   retention ids (src/routes/retention.js, staff_autonomy_changes.age)
--     WHERE created_at < ?1 ORDER BY created_at LIMIT ?2 -> idx_staff_autonomy_changes_created
--   retention delete: by id                        -> the INTEGER PRIMARY KEY
--
-- RETENTION (BH-6730 iron law, BH-6750 job): the rows are governance history,
-- made by a human, tens a year. The page reads the newest
-- staff.autonomy_changes_shown (20). staff_autonomy_changes.age removes a row
-- older than retention.staff_autonomy_changes.days (1095, three years);
-- retention.dry_run applies.
--
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_autonomy_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('autonomy','delegation')),
  class TEXT,
  from_value TEXT NOT NULL,
  to_value TEXT NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL,
  CHECK ((kind = 'autonomy') = (class IS NULL)),
  CHECK (from_value <> to_value)
);
CREATE INDEX IF NOT EXISTS idx_staff_autonomy_changes_agent_id ON staff_autonomy_changes(agent, id);
CREATE INDEX IF NOT EXISTS idx_staff_autonomy_changes_created ON staff_autonomy_changes(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.autonomy_changes_shown','20','BH-6824: autonomy and delegation changes the agent page lists, newest first (1-500)','seed','2026-10-15T00:00:00Z'),
  ('retention.staff_autonomy_changes.days','1095','BH-6824: days a staff autonomy or delegation change is kept (0 = off). Governance history made by a human, tens of rows a year.','seed','2026-10-15T00:00:00Z');
