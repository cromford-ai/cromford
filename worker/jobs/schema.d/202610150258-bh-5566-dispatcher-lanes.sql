-- BH-5566 (BH-5556.9): Dispatcher owns the eleven health lanes. One row per
-- lane in staff_lanes (0010-bh-5559-staff-charter.sql), read by the roster
-- route and the /staff screen. An ownership record only: each lane keeps its
-- script, cron line and kill switch. INSERT OR IGNORE, so a re-apply or an
-- operator's own row is left as it is.
-- Note: docs/notes/2026-10-14-BH-5566-dispatcher.md.
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('dispatcher','healthcheck','2026-10-14T20:53:00Z'),
  ('dispatcher','pipeline-health','2026-10-14T20:53:00Z'),
  ('dispatcher','heartbeat-reaper','2026-10-14T20:53:00Z'),
  ('dispatcher','hub-probe','2026-10-14T20:53:00Z'),
  ('dispatcher','jobs-watchdog','2026-10-14T20:53:00Z'),
  ('dispatcher','watchdog-ping','2026-10-14T20:53:00Z'),
  ('dispatcher','watchdog-poll','2026-10-14T20:53:00Z'),
  ('dispatcher','watchdog-responder','2026-10-14T20:53:00Z'),
  ('dispatcher','served-sha-watch','2026-10-14T20:53:00Z'),
  ('dispatcher','fleet-slo','2026-10-14T20:53:00Z'),
  ('dispatcher','lane-run-wait-alert','2026-10-14T20:53:00Z');
