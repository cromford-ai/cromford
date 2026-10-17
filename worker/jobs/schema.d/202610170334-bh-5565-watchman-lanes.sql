-- BH-5565 (BH-5556.8): Watchman owns the four security lanes. One row per
-- lane in staff_lanes (0010-bh-5559-staff-charter.sql), read by the roster
-- route and the /staff screen. An ownership record only: each lane keeps its
-- script, cron line and kill switch. INSERT OR IGNORE, so a re-apply or an
-- operator's own row is left as it is.
-- Note: docs/notes/2026-10-15-BH-5565-watchman.md.
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('watchman','security-scan','2026-10-15T08:55:00Z'),
  ('watchman','claude-auth-check','2026-10-15T08:55:00Z'),
  ('watchman','gh-pat-charge-alert','2026-10-15T08:55:00Z'),
  ('watchman','audit-tail','2026-10-15T08:55:00Z');
