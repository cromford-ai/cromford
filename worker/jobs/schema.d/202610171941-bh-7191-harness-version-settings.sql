-- ── BH-7191 (BH-7302): the fleet version check's two thresholds ─────────────
-- Read by bin/fleet-version-check.sh through setting_get; an env value
-- (HARNESS_VERSION_MAX_LAG_MIN / HARNESS_VERSION_MAX_BEAT_GAP_MIN) overrides
-- them, and a value that is not a whole number falls back to 30 with a WARN
-- log line. No table is created here (D1, not Supabase: no RLS applies).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('harness_version.max_lag_min','30','BH-7191: minutes a box harness sha may lag first-parent origin/main before one ALERTS line (fleet-version:lag:<box>)','seed','2026-10-17T00:00:00Z'),
  ('harness_version.max_beat_gap_min','30','BH-7191: minutes of heartbeat gap before the beat rule alerts (BH-7191.2; no reader yet)','seed','2026-10-17T00:00:00Z');
