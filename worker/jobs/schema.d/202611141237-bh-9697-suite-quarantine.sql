-- ── BH-9697: pre-queue suite quarantine ─────────────────────────────────────
-- A suite that is red on the PR merged with main AND red on main, and that the
-- diff did not change, is quarantined by bin/selection-gate.sh: one active row
-- per (repo, suite). bin/flaky-tier.sh files the repair ticket (repair_issue),
-- projects the active rows into CI_QUARANTINE, and releases a row after a green
-- nightly on a newer main sha (status released, main_sha_green).
-- The writer is src/routes/suite-quarantine.js. A second quarantine of a suite
-- that already has an active row is a no-op (the partial UNIQUE index). After
-- a release, a new quarantine of the same suite is a new row.
-- Note: docs/notes/2026-11-14-BH-9697-prequeue-quarantine.md.
--
-- INDEXES. Each read and the index that serves it:
--   upsert / lookup of the active row   WHERE repo=? AND suite=?
--                                       AND status='active'
--                                       uq_suite_quarantine_active (partial)
--   list one repo's rows by status      WHERE repo=? AND status=?
--                                       ORDER BY suite
--                                       idx_suite_quarantine_active; for
--                                       status='active' the planner picks
--                                       uq_suite_quarantine_active, which
--                                       also serves the ORDER BY
--   retention ids                       WHERE status='released'
--                                       AND released_at < ?
--                                       ORDER BY released_at
--                                       idx_suite_quarantine_released
--
-- RETENTION (retention.d/bh-9697-suite-quarantine.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a released row whose
-- released_at is older than suite_quarantine.retention_days (60) is deleted.
-- An active row never goes. The rows are operational: no money or history
-- value past the window.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS suite_quarantine (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  suite TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  main_sha_red TEXT NOT NULL,
  main_sha_green TEXT,
  repair_issue INTEGER,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','released')),
  created_at TEXT NOT NULL,
  released_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_suite_quarantine_active ON suite_quarantine(repo, suite) WHERE status='active';
CREATE INDEX IF NOT EXISTS idx_suite_quarantine_active ON suite_quarantine(repo, status);
CREATE INDEX IF NOT EXISTS idx_suite_quarantine_released ON suite_quarantine(status, released_at);

-- Knobs. Readers: retention.d/bh-9697-suite-quarantine.js (retention_days,
-- 0 = rule off) and src/routes/suite-quarantine.js (list_max).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('suite_quarantine.retention_days','60','BH-9697: days a released suite_quarantine row is kept. Reader: retention.d/bh-9697-suite-quarantine.js (0 = rule off, fallback 60).','seed','2026-11-14T12:37:00Z'),
  ('suite_quarantine.list_max','500','BH-9697: most rows one GET /api/suite-quarantine returns; more rows set truncated, which the client treats as unreadable. Reader: src/routes/suite-quarantine.js (1-100000, fallback 500).','seed','2026-11-14T12:37:00Z');
