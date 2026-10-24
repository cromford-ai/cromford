-- ── BH-7966 (BH-7937.2): ai_accounts ─────────────────────────────────────────
-- One row per AI account an operator added from the console (vendor + label).
-- The token is NOT here: the console seals it in the browser to the hub's
-- public key and stores only that ciphertext as a BH-7964 envelope
-- (secret_envelopes). envelope_id names that envelope. There is no state
-- column: the state is the newest secret_envelope_events row for envelope_id
-- (src/routes/ai-accounts.js accountStateFrom), so no second copy can drift.
-- Note: docs/notes/2026-10-23-BH-7966-ai-accounts.md.
--
-- vendor      claude | codex | openrouter | fireworks | xai.
-- label       ^[a-z0-9._@-]{1,48}$, never token-shaped (checkAiAccountLabel).
-- use_kind    project | pool | fallback.
-- created_by  console:<actor> (stamped by the console proxy) or `api`.
-- revoked_at  set once by POST /api/ai-accounts/:id/revoke; the row stays.
--
-- INDEXES. Each query and the index that serves it:
--   POST duplicate check  INSERT … ON CONFLICT(vendor,label) DO NOTHING
--                         ux_ai_accounts_vendor_label.
--   GET list              ORDER BY vendor, label LIMIT n
--                         ux_ai_accounts_vendor_label (no temp b-tree).
--   GET label joins       cost_rows / registry_box_accounts … IN (SELECT label
--                         FROM ai_accounts) ix_ai_accounts_label.
--   revoke                WHERE id=?1 — the TEXT PRIMARY KEY.
--
-- RETENTION. Rows are operator history (tens, at most hundreds of rows) and are
-- never deleted: revoke stamps revoked_at, and a revoked label stays taken.
-- The table does not grow with traffic, so it has no sweep.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS ai_accounts (
  id TEXT PRIMARY KEY,
  vendor TEXT NOT NULL CHECK (vendor IN ('claude','codex','openrouter','fireworks','xai')),
  label TEXT NOT NULL,
  plan TEXT,
  use_kind TEXT NOT NULL CHECK (use_kind IN ('project','pool','fallback')),
  envelope_id TEXT,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ai_accounts_vendor_label ON ai_accounts(vendor, label);
CREATE INDEX IF NOT EXISTS ix_ai_accounts_label ON ai_accounts(label);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ai_accounts_list_limit','500','BH-7966: the most rows GET /api/ai-accounts answers (1..5000; any other value answers 500). Code fallback 500 in src/routes/ai-accounts.js','seed','2026-10-23T20:44:00Z'),
  ('ai_account_status_poll_s','3','BH-7966: seconds between the console add sheet''s envelope status polls (1..60). Code fallback 3 in console-ui/src/lib/ai-accounts.js','seed','2026-10-23T20:44:00Z'),
  ('ai_account_status_wait_s','90','BH-7966: seconds the console add sheet waits for the hub apply before it says still waiting (5..900). Code fallback 90 in console-ui/src/lib/ai-accounts.js','seed','2026-10-23T20:44:00Z');
