CREATE TABLE IF NOT EXISTS locks (
  key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  holder TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  acquired_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS locks_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL, holder TEXT NOT NULL, action TEXT NOT NULL,
  outcome TEXT, at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS locks_expires ON locks(expires_at);
-- Minted per-machine tokens (2026-08-05, partner night-lane ask). Only the sha-256
-- of a token is stored — a D1 dump never yields a usable bearer credential. The
-- static HARNESS_TOKENS secret keeps working unchanged; minted tokens are a second,
-- revocable lane resolved after it.
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,          -- machine/person label, becomes the lock holder name
  token_hash TEXT NOT NULL UNIQUE,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  last_used_at INTEGER,
  role TEXT NOT NULL DEFAULT 'machine',  -- 'machine' (holds leases) | 'minter' (admin-scoped, 2026-08-21)
  prefix TEXT                            -- minter only: may mint/list/revoke names under this prefix
);
-- Catch-up for pre-2026-08-21 deployments (D1: run once, additive):
--   ALTER TABLE tokens ADD COLUMN role TEXT NOT NULL DEFAULT 'machine';
--   ALTER TABLE tokens ADD COLUMN prefix TEXT;
CREATE INDEX IF NOT EXISTS tokens_name ON tokens(name);
CREATE INDEX IF NOT EXISTS tokens_issuer_created ON tokens(created_by, created_at);
