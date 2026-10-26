-- ── BH-8452 (C0): pr_record_lists ──────────────────────────────────────────
-- One row per (repo, state): the time of the last FULL GitHub list read that
-- POST /api/pr-record-lists (src/routes/pr-record-lists.js) wrote into
-- pr_records, and how many rows it held. It is the only proof that the record
-- holds every PR of the repo in that state: GET /api/pr-records?repo=&state=
-- answers it as `sync`, and bin/lib/pr-record.sh pr_record_list trusts the
-- record list only while the stamp is no older than PR_RECORD_LIST_MAX_AGE_S.
-- repo is owner/name, lowercased. synced_at only moves forward.
--
-- INDEXES. Each query and the index that serves it:
--   the stamp read      WHERE repo = ?1 AND state = ?2
--   the stamp upsert    ON CONFLICT(repo, state)
--         ux_pr_record_lists_repo_state (repo, state): one seek.
--
-- The list cap pr_records.list_limit (default 500) bounds the GET page and
-- the rows of one POST. The code fallback is 500 (routes/pr-records.js).
--
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
-- no-retention: pr_record_lists holds at most 3 rows per fleet repo (one per state, about 30 rows); each sync overwrites its row, so the table does not grow
CREATE TABLE IF NOT EXISTS pr_record_lists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  state TEXT NOT NULL,
  synced_at TEXT NOT NULL,
  rows INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_pr_record_lists_repo_state ON pr_record_lists(repo, state);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_records.list_limit','500','BH-8452: the most rows GET /api/pr-records?state= answers (more is truncated:true) and POST /api/pr-record-lists accepts (integer 1..5000)','seed','2026-10-26T12:10:00Z');
