-- ── BH-9262 C1: the owner-approval inbox ─────────────────────────────────────
-- The hub holds no owner proof. When an owner command or an archie delegation
-- from chat meets a proof-required 403, the hub files the request here with
-- the fleet bearer (POST /api/owner-approvals, src/routes/owner-approvals.js).
-- A row grants nothing: the owner runs the action from the console through
-- the existing proved route, and then marks the row decided (decide needs the
-- human token or the Pages box-ops proof). One row per (kind, dedupe_key); the
-- key carries the chat command id, so a re-delivered message files once.
-- status is pending | approved | declined. `expired` is computed on read
-- (a pending row older than owner_approvals.pending_ttl_h) and never written.
-- Note: docs/notes/2026-11-16-BH-9262-C1-owner-approvals.md.
--
-- INDEXES. Each read and the index that serves it:
--   insert dedupe + re-read          WHERE kind=? AND dedupe_key=?
--                                    owner_approvals_key (UNIQUE)
--   pending list (the console)       WHERE status='pending' AND created_at>=?
--                                    ORDER BY created_at DESC
--                                    owner_approvals_status_created
--   expired / approved / declined    the same index, other status or range
--   all, newest first                ORDER BY created_at DESC
--                                    owner_approvals_created
--   retention ids                    WHERE created_at < ? ORDER BY created_at
--                                    owner_approvals_created
--
-- RETENTION (retention.d/bh-9262-owner-approvals.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a row older than
-- retention.owner_approvals.days (90) is deleted. The rows are an inbox, not
-- history: the action the owner ran keeps its own audit rows.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS owner_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('box_command','archie_delegation')),
  dedupe_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  actor TEXT,
  via TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','declined')),
  created_at TEXT NOT NULL,
  decided_at TEXT,
  decided_by TEXT,
  result_ref TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS owner_approvals_key ON owner_approvals(kind, dedupe_key);
CREATE INDEX IF NOT EXISTS owner_approvals_status_created ON owner_approvals(status, created_at);
CREATE INDEX IF NOT EXISTS owner_approvals_created ON owner_approvals(created_at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('owner_approvals.pending_ttl_h','72','BH-9262: hours a pending owner approval stays actionable; older pending rows read as expired. Reader: routes/owner-approvals.js (integer 1..8760, fallback 72).','seed','2026-11-16T23:05:00Z'),
  ('owner_approvals.list_limit','50','BH-9262: the most owner approvals one GET /api/owner-approvals returns (plus truncated). Reader: routes/owner-approvals.js (integer 1..1000, fallback 50).','seed','2026-11-16T23:05:00Z'),
  ('owner_approvals.payload_max_bytes','4096','BH-9262: the largest payload JSON POST /api/owner-approvals takes; bigger is 400. Reader: routes/owner-approvals.js (integer 64..65536, fallback 4096).','seed','2026-11-16T23:05:00Z'),
  ('retention.owner_approvals.days','90','BH-9262: days an owner_approvals row stays before the retention lane deletes it. Reader: retention.d/bh-9262-owner-approvals.js (0 = rule off, fallback 90).','seed','2026-11-16T23:05:00Z');
