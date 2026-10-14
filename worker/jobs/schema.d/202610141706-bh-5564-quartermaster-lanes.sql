-- BH-5564 (BH-5556.7): Quartermaster owns the seven cost lanes. One row per
-- lane in staff_lanes (0010-bh-5559-staff-charter.sql), read by the roster
-- route and the /staff screen. An ownership record only: each lane keeps its
-- script, cron line and kill switch. INSERT OR IGNORE, so a re-apply or an
-- operator's own row is left as it is.
-- Note: docs/notes/2026-10-14-BH-5564-quartermaster.md.
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('quartermaster','cost-reconcile','2026-10-14T17:06:00Z'),
  ('quartermaster','vendor-spend-pull','2026-10-14T17:06:00Z'),
  ('quartermaster','cost-local-brake','2026-10-14T17:06:00Z'),
  ('quartermaster','cap-loss-detector','2026-10-14T17:06:00Z'),
  ('quartermaster','ci-minutes-watch','2026-10-14T17:06:00Z'),
  ('quartermaster','extra-usage-track','2026-10-14T17:06:00Z'),
  ('quartermaster','orchestrator-burn','2026-10-14T17:06:00Z');
