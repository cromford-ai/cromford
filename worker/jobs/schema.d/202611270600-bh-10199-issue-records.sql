-- ── BH-10199 (slice 1): issue_records, issue_comments, issue_record_syncs ──
-- The fleet's own record of an issue or PR thread: the issue state and its
-- comments, so a lane that judges a HOLD reads one jobs GET instead of
-- issues/N plus the comment pages from GitHub.
-- Writers: POST /webhooks/github for `issues` and `issue_comment`
-- (src/lib/issue-record-intake.js, inside the wake batch), PUT
-- /api/issue-records (a full GitHub read, bin/lib/issue-record.sh), and
-- POST /api/issue-record-syncs (the per-repo list backstop).
-- Reader: GET /api/issue-records (src/routes/issue-records.js), through
-- bin/lib/issue-record.sh for hold_read and hold_check_thread.
--
-- issue_records: one row per (repo, number). repo is owner/name, lowercase.
--   gh_updated_at  GitHub's updated_at of the newest applied write. It orders
--                  writes (newer only); it is never compared with a box clock.
--   rev            THE CHANGE MARK. The worker adds 1 in the same statement
--                  that changes a stored value; a replay adds 0. A reader
--                  takes it before its GitHub read and a full write applies
--                  only while it is unchanged.
--   backfill_at    worker clock of the last full GitHub write (the issue and
--                  every comment). NULL = the record does not know all comments.
--   stale_at       the newest GitHub updated_at a list sync saw above
--                  gh_updated_at: a change no webhook brought. NULL = none.
--   truncated      1 when the stored body was cut at issue_records.body_max.
-- issue_comments: one row per (repo, comment_id). deleted = 1 is terminal.
--   seen_at is the worker clock of the last write or full read that held it.
-- issue_record_syncs: one row per repo. mark = the newest GitHub updated_at a
--   list read returned (the next `since`); synced_at = the worker clock when
--   the last COMPLETE list read was claimed; claim_at = the lease of a read.
--
-- INDEXES. Each query and the index that serves it:
--   GET row, upserts, PUT guard   WHERE repo = ? AND number = ? / ON CONFLICT(repo, number)
--         ux_issue_records_repo_number (repo, number): one seek.
--   GET comments                  WHERE repo = ? AND number = ? ORDER BY gh_created_at, comment_id LIMIT ?
--         idx_issue_comments_thread (repo, number, gh_created_at, comment_id).
--   comment upsert                ON CONFLICT(repo, comment_id)
--         ux_issue_comments_repo_id (repo, comment_id).
--   PUT marks absent comments     WHERE repo = ? AND number = ? AND deleted = 0 AND comment_id NOT IN (...)
--         idx_issue_comments_thread.
--   sync claim and write          WHERE repo = ? / ON CONFLICT(repo)
--         ux_issue_record_syncs_repo (repo).
--   retention records             WHERE refreshed_at < ? ORDER BY refreshed_at LIMIT ?
--         idx_issue_records_refreshed (refreshed_at).
--   retention comments            WHERE seen_at < ? ORDER BY seen_at LIMIT ?
--         idx_issue_comments_seen (seen_at).
--   retention deletes             WHERE id IN (...): the primary keys.
-- Proof: worker/jobs/test/issue-records.bh-10199.test.js W9 (EXPLAIN QUERY
-- PLAN on 5,000 records and 50,000 comments: SEARCH, no SCAN).
-- Rows in 12 months: issue_records about 40,000 written (10 repos, ~4,000
-- threads each), issue_comments about 400,000 written; retention keeps 30
-- days of records and 21 days of comments.
--
-- RETENTION. The record is a cache of GitHub-owned state (no money, no
-- history): rows are deleted, not archived. A deleted record reads as
-- no-record, and one GitHub read rebuilds it. A record older than
-- issue_records.backfill_max_age_s (7 days) is a miss and its next read
-- rewrites every comment (seen_at moves), so a 21-day comment rule never
-- removes a comment from a record the reader trusts. Rules:
-- issue_records.age and issue_comments.age (src/routes/retention.d/bh-10199-issue-records.js).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS issue_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  is_pr INTEGER,
  state TEXT,
  title TEXT,
  body TEXT,
  labels TEXT,
  gh_updated_at TEXT,
  rev INTEGER NOT NULL DEFAULT 1,
  backfill_at TEXT,
  stale_at TEXT,
  truncated INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  refreshed_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_issue_records_repo_number ON issue_records(repo, number);
CREATE INDEX IF NOT EXISTS idx_issue_records_refreshed ON issue_records(refreshed_at);
CREATE TABLE IF NOT EXISTS issue_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  comment_id INTEGER NOT NULL,
  author TEXT,
  author_type TEXT,
  gh_created_at TEXT,
  gh_updated_at TEXT,
  body TEXT,
  truncated INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0,
  seen_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_issue_comments_repo_id ON issue_comments(repo, comment_id);
CREATE INDEX IF NOT EXISTS idx_issue_comments_thread ON issue_comments(repo, number, gh_created_at, comment_id);
CREATE INDEX IF NOT EXISTS idx_issue_comments_seen ON issue_comments(seen_at);
-- no-retention: issue_record_syncs holds one row per fleet repo (about 10 rows); each sync overwrites its row, so the table does not grow
CREATE TABLE IF NOT EXISTS issue_record_syncs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  mark TEXT,
  synced_at TEXT,
  claim_at TEXT,
  rows INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_issue_record_syncs_repo ON issue_record_syncs(repo);
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('issue_records.backfill_max_age_s','604800','BH-10199: seconds a full GitHub read of an issue thread is trusted; an older record is a miss (backfill-old) and the next read rewrites it','seed','2026-11-27T06:00:00Z'),
  ('issue_records.sync_max_age_s','1800','BH-10199: seconds the last complete per-repo list sync is trusted; older is a miss (sync-old)','seed','2026-11-27T06:00:00Z'),
  ('issue_records.sync_every_s','600','BH-10199: seconds between two per-repo list reads (issues?since=); also the claim lease','seed','2026-11-27T06:00:00Z'),
  ('issue_records.sync_pages_max','5','BH-10199: pages of 100 one list sync reads; more is an incomplete sync (the mark moves, synced_at does not)','seed','2026-11-27T06:00:00Z'),
  ('issue_records.body_max','65536','BH-10199: characters of an issue or comment body the record stores; a longer body is cut and marked truncated (a reader miss)','seed','2026-11-27T06:00:00Z'),
  ('issue_records.comments_max','1000','BH-10199: comments one thread read returns; more is a miss (too-many) and one full write takes at most this many','seed','2026-11-27T06:00:00Z'),
  ('issue_records.items_max','500','BH-10199: issues one list sync POST takes; more is a 400','seed','2026-11-27T06:00:00Z'),
  ('retention.issue_records.days','30','BH-10199: days an issue record is kept after its last write (0 = off); a deleted row reads as no-record','seed','2026-11-27T06:00:00Z'),
  ('retention.issue_comments.days','21','BH-10199: days a stored issue comment is kept after its last write or full read (0 = off); keep it above issue_records.backfill_max_age_s','seed','2026-11-27T06:00:00Z');
