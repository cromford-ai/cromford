-- ── BH-10215: pr_base_seqs ──────────────────────────────────────────────────
-- The base sequence of each (repo, base branch). Each `push` webhook to a base
-- branch raises seq by 1 (worker/jobs/src/lib/pr-base-seq.js, BASE_SEQ_SQL,
-- run by src/lib/pr-record-intake.js). A base branch is the repo's default
-- branch, or a branch that is the base_ref of an open pr_records row. seq only
-- grows (seq + 1), and a push with the same `after` sha as last_sha changes 0
-- rows, so a replayed delivery changes nothing. pr_records.mergeable_base_seq
-- (core.d/bh-10215-pr-base-seq.js) holds the seq at which a row's
-- mergeable_state was read from GitHub; bin/lib/pr-record-serve.sh serves the
-- row while the two are equal. The read route is GET /api/pr-base-seqs
-- (src/routes/pr-base-seqs.js).
--
-- INDEXES. Each query and the index that serves it:
--   the push upsert       ON CONFLICT(repo, base_ref): the primary key
--                         (sqlite_autoindex_pr_base_seqs_1). Its EXISTS reads
--                         pr_records WHERE repo=? AND state='open' AND base_ref=?
--                         through an index on (repo, state): ANALYZE picks
--                         idx_pr_records_repo_state_upd or _created.
--   the read route        WHERE repo = ?1 LIMIT ?2: the primary key prefix.
--   retention id read     WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2
--                         idx_pr_base_seqs_updated (updated_at).
-- EXPLAIN QUERY PLAN on 2,000 pr_base_seqs rows and 5,000 pr_records rows
-- (test W10 of worker/jobs/test/pr-base-seq.bh-10215.test.js):
--   read       SEARCH pr_base_seqs USING INDEX sqlite_autoindex_pr_base_seqs_1 (repo=?)
--   upsert     SCAN CONSTANT ROW | SCALAR SUBQUERY 1 |
--              SEARCH pr_records USING INDEX idx_pr_records_repo_state_created (repo=? AND state=?)
--   retention  SEARCH pr_base_seqs USING COVERING INDEX idx_pr_base_seqs_updated (updated_at<?)
--
-- ROWS. Under 2,000 in 12 months: one row per default branch plus one per
-- stacked base branch.
--
-- RETENTION (rule pr_base_seqs.age, routes/retention.d/bh-10215-pr-base-seqs.js,
-- the hourly bin/d1-retention.sh lane). A row is a cache key, not money or
-- history: a deleted row reads as "no row", which the conductor treats as a
-- miss and pays one GitHub read. Rows not written for
-- retention.pr_base_seqs.days (30) are deleted. retention.dry_run applies.
--
-- KNOBS (settings rows; the code fallbacks name them):
--   pr_base_seqs.read_limit        rows one GET /api/pr-base-seqs answers (500)
--   retention.pr_base_seqs.days    the retention window (30)
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS pr_base_seqs (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  seq INTEGER NOT NULL,
  last_sha TEXT,
  pushed_at TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, base_ref)
);
CREATE INDEX IF NOT EXISTS idx_pr_base_seqs_updated ON pr_base_seqs(updated_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_base_seqs.read_limit','500','BH-10215: rows one GET /api/pr-base-seqs?repo= answers (whole number 1..5000; code default 500). A repo has one row per base branch.','seed','2026-11-26T11:21:00Z'),
  ('retention.pr_base_seqs.days','30','BH-10215: days a pr_base_seqs row is kept after its last write (0 = off). A deleted row only costs the conductor one GitHub read.','seed','2026-11-26T11:21:00Z');
