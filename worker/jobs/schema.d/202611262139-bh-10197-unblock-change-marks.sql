-- ── BH-10197: the unblock lane's change marks ───────────────────────────────
-- One row per (repo, site, pr). site is the unblock collector that reads the
-- PR: queue or review. mark is the newest wakes.id for the PR (kind pr) and
-- for its ticket issue (kind issue) when the collector's reads started; 0 =
-- no wake. settled = 1 when that newest wake's minute was over at the read
-- (the wakes dedupe drops a second wake in the same minute). fields holds the
-- compact GitHub-only answers of the PR (queue: cr, tt, cdate; review: rv,
-- fc). checked_at is the worker clock at the commit.
-- Writer: POST /api/unblock/change-marks/commit (src/routes/unblock-change-marks.js).
-- Reader: POST /api/unblock/change-marks/check. Hub caller: bin/lib/unblock/change-gate.sh.
-- The index for each query:
--   the check's stored-row read  WHERE repo=? AND site=? AND pr IN (...)  ux_unblock_change_marks_key
--   the commit's upsert          ON CONFLICT(repo, site, pr)              ux_unblock_change_marks_key
--   the retention read           WHERE checked_at < ? ORDER BY checked_at idx_unblock_change_marks_checked
--   the check's marks read       wakes WHERE repo IN (..) AND kind=? AND key IN (..)  idx_wakes_dedupe
-- Proof: worker/jobs/test/unblock-change-marks.bh-10197.test.js W9 (EXPLAIN
-- QUERY PLAN on 5,000 marks rows and 20,000 wakes: SEARCH, no SCAN).
-- Rows: about 30,000 in 12 months (10 repos x ~1,500 PRs per 14 days x 2
-- sites), bounded by retention.unblock_change_marks.days (14,
-- src/routes/retention.d/bh-10197-unblock-change-marks.js). The rows are a
-- cache: a deleted row reads as first seen and one read rebuilds it.
-- D1 (SQLite), not Supabase: no RLS applies.
CREATE TABLE IF NOT EXISTS unblock_change_marks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  site TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head TEXT NOT NULL,
  mark INTEGER NOT NULL,
  settled INTEGER NOT NULL,
  fields TEXT NOT NULL DEFAULT '{}',
  checked_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_unblock_change_marks_key ON unblock_change_marks(repo, site, pr);
CREATE INDEX IF NOT EXISTS idx_unblock_change_marks_checked ON unblock_change_marks(checked_at);
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.change_marks.items_max','200','BH-10197: the most PRs one POST /api/unblock/change-marks check or commit takes; more is a 400','seed','2026-11-26T21:39:00Z'),
  ('unblock.change_marks.fields_max_bytes','32768','BH-10197: the largest fields JSON one change-marks row stores; a bigger item is refused, not stored','seed','2026-11-26T21:39:00Z'),
  ('retention.unblock_change_marks.days','14','BH-10197: days an unblock_change_marks row is kept (0 = off); a deleted row reads as first seen and one read rebuilds it','seed','2026-11-26T21:39:00Z');
