-- ── BH-7260 (BH-7244.2): the PM flesh-out ledger ───────────────────────────
-- bin/pm-flesh.sh <project> <idea-id> writes one row per (project, idea,
-- input hash). The rows are the dedup ledger of one billed model call and its
-- result. The row IS the claim, made BEFORE the call. status is claimed |
-- answered | done | failed (checked in JS, src/routes/pm.js):
--   claimed   the call is billed or running, no result is stored yet
--   answered  the result is stored, the draft and the cost are not
--   done      result_ref, draft and cost_usd are stored too
--   failed    the call or its answer failed (billed)
-- Only a person (pm-flesh.sh --force) re-claims a claimed or failed row. An
-- answered or done row is never re-claimed.
--   result      the seven-section flesh-out (at most pm.flesh_result_max_chars)
--   result_ref  the console link <console>/roadmap/<p>/idea/<id>#pm-flesh
--   draft       ok | skipped | failed | unknown, the PRD and mockup outcome
--   prd         the PRD bin/draft-proposal.sh wrote (prd.md), kept so the
--               paid draft outlives the run's temp dir (at most
--               pm.flesh_prd_max_chars, pm-flesh cuts a longer one and says so)
--   cost_usd    the spend of the run (the logs/cost.csv rows of its run id).
--               It is money, so retention archives the row and never only
--               deletes it.
-- Writer and reader: src/routes/pm.js. Note: docs/notes/2026-10-30-BH-7260-pm-flesh.md.
--
-- INDEXES. Each query and the index that serves it:
--   claim conflict, key read and force CAS
--         WHERE project=?1 AND idea_id=?2 AND input_hash=?3   ux_pm_runs_key
--   result and read-back   WHERE id=?1 AND project=?2   the primary key
--   runs of a project      WHERE project=?1 ORDER BY created_at DESC
--         idx_pm_runs_project_created
--   runs of an idea, newest result
--         WHERE project=?1 AND idea_id=?2 ORDER BY created_at DESC
--         idx_pm_runs_idea_created
--   retention ids          WHERE created_at < ?1 ORDER BY created_at
--         idx_pm_runs_created
--
-- RETENTION (src/routes/retention.d/bh-7260-pm-runs.js, on the hourly
-- bin/d1-retention.sh lane). pm_runs.age copies a row to the archive D1
-- before the delete, after pm.retention_days (180). With the archive unbound
-- it deletes nothing. retention.dry_run (seed 1) applies.
-- D1 is SQLite, not Supabase, so RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pm_runs (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  idea_id TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  status TEXT NOT NULL,
  model TEXT,
  result TEXT,
  result_ref TEXT,
  draft TEXT,
  prd TEXT,
  cost_usd REAL,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_pm_runs_key ON pm_runs(project, idea_id, input_hash);
CREATE INDEX IF NOT EXISTS idx_pm_runs_project_created ON pm_runs(project, created_at);
CREATE INDEX IF NOT EXISTS idx_pm_runs_idea_created ON pm_runs(project, idea_id, created_at);
CREATE INDEX IF NOT EXISTS idx_pm_runs_created ON pm_runs(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pm.retention_days','180','BH-7260: days a PM flesh-out run stays hot before it moves to the archive (0 = off)','seed','2026-10-30T19:16:00Z'),
  ('pm.runs_shown','50','BH-7260: PM flesh-out runs GET /api/pm/runs lists (1..200)','seed','2026-10-30T19:16:00Z'),
  ('pm.flesh_result_max_chars','32768','BH-7260: characters of one PM flesh-out result (1024..262144). pm-flesh fails a longer answer, the worker refuses more','seed','2026-10-30T19:16:00Z'),
  ('pm.flesh_prd_max_chars','131072','BH-7260: characters of the PRD a PM flesh-out run keeps (1024..262144). pm-flesh cuts a longer one with a note, the worker refuses more','seed','2026-10-30T19:16:00Z'),
  ('pm.flesh_timeout_s','900','BH-7260: seconds the PM flesh-out model call may run (60..2400)','seed','2026-10-30T19:16:00Z'),
  ('pm.land_max','20','BH-7260: SYNTH ideas pm_ideas_land lands per run-product cycle (0..100, 0 = landing off)','seed','2026-10-30T19:16:00Z');
