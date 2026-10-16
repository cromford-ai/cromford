-- ── BH-6744 (wave 1 of #6541): landing_decisions ────────────────────────────
-- One row per (repo, PR number, head, landing mode): what the conductor WOULD
-- have done with a READY PR under the landing contract (bin/lib/mc/landing.sh).
-- would = direct | queue; reason = the one token landing_eligible answered
-- (`ok` when would = direct). Shadow only: nothing reads this table to decide
-- a merge. The writer is landing_shadow (POST /api/landing-decisions, insert
-- once); the readers are GET /api/landing-decisions and the retention rule.
--
-- INDEXES. Each query and the index that serves it:
--   POST  INSERT ... ON CONFLICT(repo, number, head, mode) DO NOTHING
--         the UNIQUE constraint's autoindex.
--   GET   WHERE repo=?1 AND (?2 IS NULL OR number=?2) ORDER BY id DESC
--         idx_landing_decisions_repo_id (repo, id): one index range in id
--         order, no sort. With number= the UNIQUE autoindex's (repo, number)
--         prefix can serve it too.
--   retention id read  WHERE at < ?1 ORDER BY at
--         idx_landing_decisions_at (at).
--
-- RETENTION (src/routes/retention.js rule landing_decisions.age, the hourly
-- bin/d1-retention.sh lane). A decision is a shadow diagnostic: wave 5 of
-- #6541 replays the last weeks of them to decide the flip, and an older row
-- has no reader. Rows older than retention.landing_decisions.days (90) are
-- deleted, not archived: they are not money or history of record.
-- retention.dry_run (seed 1) applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS landing_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  head TEXT NOT NULL,
  mode TEXT NOT NULL,
  would TEXT NOT NULL,
  reason TEXT NOT NULL,
  at TEXT NOT NULL,
  UNIQUE (repo, number, head, mode)
);
CREATE INDEX IF NOT EXISTS idx_landing_decisions_repo_id ON landing_decisions(repo, id);
CREATE INDEX IF NOT EXISTS idx_landing_decisions_at ON landing_decisions(at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.landing_decisions.days','90','BH-6744: days a landing shadow decision is kept (0 = off). Wave 5 replays the last weeks of decisions; older rows have no reader.','seed','2026-10-15T19:55:00Z');
