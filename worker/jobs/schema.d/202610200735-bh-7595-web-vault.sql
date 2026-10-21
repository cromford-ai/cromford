-- BH-7595 (slice C0): the web_vault credential store. routes/web-vault.js
-- writes and reads it; contract: docs/notes/2026-10-19-BH-7595-web-vault.md.
--
-- web_vault holds one AES-GCM ciphertext per (project, site, field). No column
-- holds a plain value. key_id names the Worker secret WEB_VAULT_KEY_<n> the row
-- was encrypted with, so a key can rotate row by row. last_used_at is the write
-- time on a set and the read time on an ok read, so the stale report is one
-- range on one index. RETENTION: none by design. A row unused for
-- web_vault.retain_days is REPORTED (GET /api/web-vault/entries?stale=1,
-- bin/web-vault.sh stale) and never deleted automatically (ticket item 2).
CREATE TABLE IF NOT EXISTS web_vault (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  site TEXT NOT NULL,
  field TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  iv TEXT NOT NULL,
  key_id INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL
);
-- The set upsert (ON CONFLICT), the read (project=? AND site=? AND field=?) and
-- the list (project=? [AND site=?] ORDER BY site, field). Its (project, site)
-- prefix is the (project, site) index.
CREATE UNIQUE INDEX IF NOT EXISTS uq_web_vault_entry ON web_vault(project, site, field);
-- The stale read: last_used_at < ? ORDER BY last_used_at LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_web_vault_last_used ON web_vault(last_used_at);

-- One row per set and per read, ok or refused. Never a value, never a token.
-- RETENTION: rule web_vault_audit.age in routes/retention.js, window
-- retention.web_vault_audit.days (90), under retention.dry_run. Rows are
-- history, so they are copied to the archive D1 before the delete.
CREATE TABLE IF NOT EXISTS web_vault_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('set','read')),
  outcome TEXT NOT NULL,
  project TEXT NOT NULL,
  site TEXT NOT NULL,
  field TEXT NOT NULL,
  actor TEXT NOT NULL,
  run_id INTEGER,
  key_id INTEGER
);
-- The retention id read: at < ? ORDER BY at LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_web_vault_audit_at ON web_vault_audit(at);
-- The audit read: project=? [AND site=?] ORDER BY at DESC LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_web_vault_audit_entry ON web_vault_audit(project, site, at);

-- One row per claimed web-task run: the SHA-256 (hex) of the random run token
-- POST /api/lane-runs/claim minted for that claim. The token itself is in the
-- claim answer only, never in D1. POST /api/web-vault/read needs the token
-- (x-web-vault-run-token) and the machine of this row, so a bearer holder who
-- only knows run_id and machine is refused (bad_token). A new claim of the same
-- run replaces the row, so the token of an older claim stops working.
-- The read and the upsert use the run_id PRIMARY KEY.
-- RETENTION: rule web_vault_run_token.age in routes/retention.js, window
-- retention.web_vault_run_token.days (2), under retention.dry_run. A row is a
-- short-lived credential hash, not history, so it is deleted, not archived.
CREATE TABLE IF NOT EXISTS web_vault_run_token (
  run_id INTEGER PRIMARY KEY,
  machine TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  created_at TEXT NOT NULL
);
-- The retention id read: created_at < ? ORDER BY created_at LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_web_vault_run_token_at ON web_vault_run_token(created_at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('web_vault.key_id','1','BH-7595: the key id a web_vault set encrypts with (Worker secret WEB_VAULT_KEY_<n>, 1..999); a row keeps its own key_id, so older rows read until re-set; the code default is 1','seed','2026-10-19T00:00:00Z'),
  ('web_vault.retain_days','180','BH-7595: a web_vault row unused this many days is reported by bin/web-vault.sh stale (1..3650); never deleted automatically; the code default is 180','seed','2026-10-19T00:00:00Z'),
  ('retention.web_vault_audit.days','90','BH-7595: days a web_vault_audit row is kept before the hourly retention run archives it (0 = off); the code default is 90','seed','2026-10-19T00:00:00Z'),
  ('retention.web_vault_run_token.days','2','BH-7595: days a web_vault_run_token row (the hash of a web-task claim token) is kept before the hourly retention run deletes it (0 = off); the code default is 2','seed','2026-10-19T00:00:00Z');
