-- ── BH-7964 (BH-7937.0): secret_envelopes, secret_envelope_events ───────────
-- The one-time secret envelope. A caller (the console) stores a ciphertext
-- sealed to the hub's public key with POST /api/secrets/envelope; the hub reads
-- it ONCE with GET /api/secrets/envelope/:id (src/routes/secret-envelopes.js),
-- and the read deletes the row. The worker only ever holds ciphertext: it holds
-- no key and decrypts nothing. Note: docs/notes/2026-10-22-BH-7964-secret-envelopes.md.
--
-- secret_envelopes.id         crypto.randomUUID().
-- secret_envelopes.scope      ai-account:<name> or tracker:<name> (checkEnvelopeScope).
-- secret_envelopes.ciphertext base64, 344..1024 chars (RSA-OAEP-2048 = 344).
-- created_at / expires_at     YYYY-MM-DDTHH:MM:SSZ, expires_at = created_at
--                             + settings secret_envelope_ttl_s (code default 900).
-- secret_envelope_events      append-only audit: stored, consumed, expired. detail
--                             is a fixed reason word (200 chars max), never a value.
--
-- INDEXES. Each query and the index that serves it:
--   POST insert      INSERT INTO secret_envelopes — the TEXT PRIMARY KEY.
--   GET read         DELETE FROM secret_envelopes WHERE id=?1 RETURNING … — the PK.
--   expiry select    WHERE expires_at < ?1 ORDER BY expires_at LIMIT ?2
--         (ENVELOPE_EXPIRED_SQL, the BH-7937.2 sweep) ix_secret_envelopes_expires.
--   status read      secret_envelope_events WHERE envelope_id=?1 (BH-7937.3)
--         ix_secret_envelope_events_env.
--   events retention WHERE at < ?1 ORDER BY at ix_secret_envelope_events_at.
--
-- RETENTION. secret_envelopes: a row dies on its one read; an expired row is
-- refused and deleted on read, and the BH-7937.2 sweep deletes the expired rows
-- nobody read (ix_secret_envelopes_expires). secret_envelope_events: history, so
-- the BH-7937.2 retention rule on `at` archives it, never a silent delete.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS secret_envelopes (
  id TEXT PRIMARY KEY,
  scope TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_secret_envelopes_expires ON secret_envelopes(expires_at);
CREATE TABLE IF NOT EXISTS secret_envelope_events (
  id INTEGER PRIMARY KEY,
  envelope_id TEXT,
  scope TEXT,
  event TEXT NOT NULL,
  detail TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_secret_envelope_events_env ON secret_envelope_events(envelope_id);
CREATE INDEX IF NOT EXISTS ix_secret_envelope_events_at ON secret_envelope_events(at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('secret_envelope_ttl_s','900','BH-7964: seconds a secret envelope lives before the hub must read it (60..86400). Code default 900','seed','2026-10-22T04:11:00Z'),
  ('hub_envelope_public_key','','BH-7964: the hub public key a caller seals an envelope to. Empty until BH-7937.2 fills it','seed','2026-10-22T04:11:00Z');
