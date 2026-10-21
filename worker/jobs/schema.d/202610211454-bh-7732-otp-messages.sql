-- ── BH-7732: otp_messages ───────────────────────────────────────────────────
-- The otp inbox. Cloudflare Email Routing on otp.example.com (catch-all)
-- hands each message to the Email Worker harness-otp-inbox
-- (worker/otp-inbox/src/index.js), which parses it and writes ONE row here. A
-- web-task lane reads the newest code for its address through GET /api/otp
-- (src/routes/otp.js) with bin/otp-wait.sh. A code is a short-lived secret:
-- it is never logged, and the row is deleted after one day.
-- No raw email body is stored. Note: docs/notes/2026-10-20-BH-7732-otp-inbox.md.
--
-- recipient  the envelope `to`, trimmed and lowercased (at write and lookup).
-- message_id the Message-ID header, trimmed (<> kept); with none,
--            'fp:' + sha256(from|to|subject|Date header).
-- code       the parsed code; NULL when parse_status is not 'code'.
-- received_at the worker clock at receipt, YYYY-MM-DDTHH:MM:SSZ.
--
-- INDEXES. Each query and the index that serves it:
--   email() insert  ON CONFLICT(recipient, message_id) DO NOTHING
--         uq_otp_messages_msg (the dedup: a second delivery writes no row).
--   GET /api/otp    WHERE recipient=?1 AND received_at>=?2 AND code IS NOT NULL
--         ORDER BY received_at DESC, id DESC LIMIT 1
--         idx_otp_messages_recipient (recipient, received_at).
--   retention, ids  WHERE received_at < ?1 ORDER BY received_at
--         idx_otp_messages_received.
--   retention delete WHERE id IN (json_each) — the INTEGER PRIMARY KEY.
--
-- RETENTION (src/routes/retention.js rule otp_messages.age, the hourly
-- bin/d1-retention.sh lane). A row is deleted retention.otp_messages.days (1)
-- after it was received. Not money, not history: delete, not archive.
-- retention.dry_run applies, with its one retention_runs row per rule per run.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS otp_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  sender TEXT NOT NULL,
  subject TEXT,
  code TEXT,
  parse_status TEXT NOT NULL CHECK (parse_status IN ('code','no_code','too_large')),
  received_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_otp_messages_msg ON otp_messages(recipient, message_id);
CREATE INDEX IF NOT EXISTS idx_otp_messages_recipient ON otp_messages(recipient, received_at);
CREATE INDEX IF NOT EXISTS idx_otp_messages_received ON otp_messages(received_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.otp_messages.days','1','BH-7732: days an otp_messages row is kept (codes are short-lived secrets; 0 = off). Code default 1','seed','2026-10-20T16:37:00Z');
