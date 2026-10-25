-- ── BH-7965 (BH-7937.2): the secret envelope sweep knobs ────────────────────
-- Read by POST /api/secrets/envelope/sweep (src/routes/secret-envelope-apply.js),
-- which bin/secret-envelope-sweep.sh calls hourly on the hub.
--   secret_envelope_events_retention_days  days a secret_envelope_events row
--       stays in the hot table; older rows are copied to the archive (env.ARCHIVE)
--       and then deleted. Code fallback 90 for a value outside 1..3650.
--   secret_envelope_sweep_batch  rows per table per sweep call (1..5000). Code
--       fallback 500.
-- No CREATE TABLE: the tables and their indexes are BH-7964's.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('secret_envelope_events_retention_days','90','BH-7965: days a secret_envelope_events row stays before the sweep archives and deletes it (1..3650). Code default 90','seed','2026-10-23T08:00:00Z'),
  ('secret_envelope_sweep_batch','500','BH-7965: rows per table one secret envelope sweep call deletes (1..5000). Code default 500','seed','2026-10-23T08:00:00Z');
