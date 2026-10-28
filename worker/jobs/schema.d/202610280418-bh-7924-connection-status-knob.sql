-- ── BH-7924: the connection status bound ───────────────────────────────────
-- connection.status_max_bytes caps the JSON that POST
-- /api/connections/<p>/status stores in connection.<p>.status
-- (routes/connections.js statusMaxBytes; fallback 2048, valid 2048..16384,
-- a value outside the range is ignored). The floor fits every status
-- bin/connection-probe.sh can send (error at most 1500 JSON bytes).
-- No table here, so no index. Only INSERT OR IGNORE: a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('connection.status_max_bytes','2048','BH-7924: the most bytes of status JSON POST /api/connections/<p>/status stores in connection.<p>.status (2048..16384; larger is a 413).','seed','2026-10-27T19:00:00Z');
