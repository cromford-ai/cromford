-- ── BH-8067: pr_records ─────────────────────────────────────────────────────
-- One row per fleet-owned PR: the fleet's own record of the PR state the
-- polling lanes read from GitHub today. A write updates it first (C0: the PR
-- open in bin/lib/gh-pr-create.sh), a webhook second (C2), and
-- bin/lib/pr-record.sh pr_record_get reads GitHub only when the record does
-- not know a requested field or is older than PR_RECORD_MAX_AGE_S. Writer and
-- reader: PUT and GET /api/pr-records (src/routes/pr-records.js).
--
-- repo is owner/name, lowercased at write and lookup. Every value column is
-- NULL until a source sets it (NULL = unknown). fields_at is a JSON object
-- {column: ISO time of the stored value}: a write replaces a column only when
-- its time is >= the stored one. refreshed_at is the last write from any
-- source (fleet, webhook, github).
--
-- INDEXES. Each query and the index that serves it:
--   GET and the upsert     WHERE repo = ?1 AND number = ?2 / ON CONFLICT(repo, number)
--         ux_pr_records_repo_number (repo, number): one seek.
--   retention closed       WHERE state IN ('closed','merged') AND refreshed_at < ?1
--                          ORDER BY state, refreshed_at LIMIT ?2
--         idx_pr_records_state_refreshed (state, refreshed_at).
--   retention age          WHERE refreshed_at < ?1 ORDER BY refreshed_at LIMIT ?2
--         idx_pr_records_refreshed (refreshed_at).
--   retention delete       WHERE id IN (...): the primary key.
-- test/pr-records.bh-8067.test.js proves each one on 5,000 rows.
--
-- RETENTION. The record is a cache of GitHub-owned state (no money, no
-- history), so rows are deleted, not archived. A closed or merged PR keeps
-- value for retention.pr_records.closed_days (14) after its last write; any
-- row for retention.pr_records.days (90). A deleted row reads as unknown: one
-- GitHub read rebuilds it. The rules are pr_records.closed and pr_records.age
-- in src/routes/retention.js.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pr_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  state TEXT,
  draft INTEGER,
  head_ref TEXT,
  base_ref TEXT,
  head_sha TEXT,
  base_sha TEXT,
  mergeable_state TEXT,
  labels TEXT,
  checks TEXT,
  review_decision TEXT,
  queue_state TEXT,
  last_comment_id INTEGER,
  fields_at TEXT NOT NULL DEFAULT '{}',
  last_source TEXT,
  gh_read_at TEXT,
  webhook_at TEXT,
  created_at TEXT NOT NULL,
  refreshed_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_pr_records_repo_number ON pr_records(repo, number);
CREATE INDEX IF NOT EXISTS idx_pr_records_state_refreshed ON pr_records(state, refreshed_at);
CREATE INDEX IF NOT EXISTS idx_pr_records_refreshed ON pr_records(refreshed_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.pr_records.closed_days','14','BH-8067: days a closed or merged PR record is kept after its last write (0 = off)','seed','2026-10-22T19:47:00Z'),
  ('retention.pr_records.days','90','BH-8067: days any PR record is kept after its last write (0 = off)','seed','2026-10-22T19:47:00Z');
