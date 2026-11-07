-- ── BH-9154: lead_ticket_verdicts ────────────────────────────────────────────
-- Fix 3 of #9066: one lead review per ticket per real diff in 24 h. After a
-- done lead review of a worklist head, bin/lib/lead-review/result.sh stores
-- the lead's word under (repo, ticket key, patch fingerprint): the ticket key
-- of the PR's branch or title and patch_review_fp (bin/lib/patch-fp.sh) of the
-- head. Gate 52 (bin/lib/lead-gates.d/52-ticket-replay.sh) reads it for a
-- second PR of the same ticket and, for a MERGE or MERGE-WITH-NOTES inside its
-- window, posts that word with no model call. A later word on the same key
-- replaces the row (a BLOCK over a MERGE stops the replay).
-- repo is lower case and ticket_key upper case (normalized by the route).
-- The route contract is the header of worker/jobs/src/routes/lead-ticket-verdicts.js.
--
-- INDEXES. Each query and the index that serves it:
--   POST upsert / GET  WHERE repo=? AND ticket_key=? AND patch_fp=? [AND created_at >= ?]
--         the primary key (repo, ticket_key, patch_fp).
--   retention id read  WHERE created_at < ?1 ORDER BY created_at
--         idx_lead_ticket_verdicts_created (created_at).
--
-- RETENTION (rule lead_ticket_verdicts.age, the hourly bin/d1-retention.sh
-- lane). A row is worth something only inside the replay window (24 h by
-- default, LEAD_TICKET_REPLAY_WINDOW_S at most 7 days). Rows older than
-- retention.lead_ticket_verdicts.days (7) are deleted, not archived: the
-- verdict itself stays in the verdicts table. retention.dry_run (seed 1)
-- applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS lead_ticket_verdicts (
  repo TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  patch_fp TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,
  verdict TEXT NOT NULL,
  review_mode TEXT,
  report_ref TEXT,
  request_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (repo, ticket_key, patch_fp)
);
CREATE INDEX IF NOT EXISTS idx_lead_ticket_verdicts_created ON lead_ticket_verdicts(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.lead_ticket_verdicts.days','7','BH-9154: days a lead_ticket_verdicts row is kept (0 = off). The replay window is 24 h (LEAD_TICKET_REPLAY_WINDOW_S, at most 7 days), so older rows are never read.','seed','2026-11-06T10:40:00Z');
