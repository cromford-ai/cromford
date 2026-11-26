-- ── BH-9503 (C1 of #8973): ticket_status_comments ───────────────────────────
-- The delivery ledger of the ONE in-place status comment per ticket. A row says
-- which GitHub comment carries a ticket's status and the fingerprint of the
-- body last written to it. It is NOT a state store: the ticket's state is
-- always C0's live read (routes/ticket-status.js loadTickets). The routes are
-- in worker/jobs/src/routes/ticket-status-comment.js; the hub lane
-- bin/ticket-status-comment.sh is the only writer.
--
-- INDEXES. Each query and the index that serves it:
--   due, the watch set   WHERE project=? AND final=0 AND updated_at >= ? ORDER BY updated_at
--         idx_ticket_status_comments_watch (project, final, updated_at).
--   due, the open queue rows' comment rows (JOIN on project, ticket_key) and
--   the POST upsert      the primary key (project, ticket_key).
--   retention id read    WHERE updated_at < ?1 ORDER BY updated_at
--         idx_ticket_status_comments_updated (updated_at).
--
-- RETENTION (rule ticket_status_comments.age, routes/retention.d/
-- bh-9503-ticket-status-comments.js, the hourly bin/d1-retention.sh lane).
-- A row is a delivery pointer, not money or history: the comment stays on
-- GitHub, and a lost row is found again by its marker (the lane's adopt step).
-- Rows not written for retention.ticket_status_comments.days (90) are deleted.
-- retention.dry_run applies: the first runs only count.
--
-- KNOBS (settings rows; the code fallbacks name them):
--   ticket_status_comment.batch_max   due tickets per project per call
--   ticket_status_comment.watch_days  how long a non-final row stays watched
--   ticket_status_comment.not_before  NOT seeded: the due route stamps it once
--     (INSERT OR IGNORE) on its first call. A running attempt that started
--     before it gets no comment until that attempt ends (the deploy guard).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS ticket_status_comments (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  issue INTEGER NOT NULL,
  comment_id INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,
  state TEXT NOT NULL,
  final INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
CREATE INDEX IF NOT EXISTS idx_ticket_status_comments_watch ON ticket_status_comments(project, final, updated_at);
CREATE INDEX IF NOT EXISTS idx_ticket_status_comments_updated ON ticket_status_comments(updated_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ticket_status_comment.batch_max','20','BH-9503: tickets one GET /api/ticket-status-comments/due answers per project, sorted by key; more sets truncated and the rest come on the next call (whole number >= 1; code default 20).','seed','2026-11-11T07:22:00Z'),
  ('ticket_status_comment.watch_days','14','BH-9503: days a non-final ticket_status_comments row stays in the due scan after its last write, so a reaped ticket with no open queue row still gets its edits (whole number >= 1; code default 14).','seed','2026-11-11T07:22:00Z'),
  ('retention.ticket_status_comments.days','90','BH-9503: days a ticket_status_comments row is kept after its last write (0 = off). The comment itself stays on GitHub; a deleted row is found again by its marker.','seed','2026-11-11T07:22:00Z');
