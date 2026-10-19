-- BH-6890 (BH-6881.6): the merge conductor for one whole project on a
-- lane-run machine. bin/lib/lane-placement.sh reads
-- lane_placement.<lane>.<project> before lane_placement.<lane>, and
-- bin/lib/mc/project-placement.sh reads lane_fallback.merge-conductor.<project>
-- (hub | off). The proof project is project-6-os. Both rows ship OFF: the
-- placement is hub (anything but fly is hub) and the fallback is hub (today's
-- path when a row is stale or failed). The flip is a data change after merge:
--   lane_placement.merge-conductor.project-6-os = fly
-- Rollback: set it back to hub. No new table and no new index: the hub's read
-- of a project's rows (GET /api/lane-runs/by-prefix?lane=merge-conductor&
-- project_prefix=<project>) is served by idx_lane_runs_lane_project
-- (202610142107-bh-6495-conductor-fly.sql). Five knob rows: the ALERTS line
-- interval, the hub's publish interval, the machine-failed streak that raises
-- an ALERTS line with the fallback on, the hub mark's max age, and the
-- no-capacity backoff.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.merge-conductor.project-6-os','hub','BH-6890: fly = the hub tick of project-6-os enqueues one merge-conductor lane_runs row and a lane-run machine runs bin/merge-conductor-project.sh project-6-os under the project lease; hub (seeded) or anything but fly = today''s hub tick','seed','2026-10-19T00:00:00Z'),
  ('lane_fallback.merge-conductor.project-6-os','hub','BH-6890: hub (seeded) = a stale or failed project-6-os project row, or one that left work to the hub, makes the hub run that tick; off = one ALERTS line per hour and the hub runs nothing for project-6-os (#6895 turns it off after 24 h with 0 fallbacks)','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.alert_s','3600','BH-6890: with lane_fallback.merge-conductor.<project>=off, at most one ALERTS line per project per this many seconds for a stale or failed project row (1..86400); the code default is 3600','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.publish_min_s','120','BH-6890: the hub publishes a fly project''s merge-conductor snapshot just before it enqueues the row, at most once per this many seconds per project (1..86400); the cron publisher is the backstop; the code default is 120','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.failed_alert_n','3','BH-6890: with lane_fallback.merge-conductor.<project>=hub, this many machine-failed project rows in a row raise one held ALERTS line (1..86400); the code default is 3','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.hubtick_max_s','3600','BH-6890: a hub take-back mark older than this many seconds no longer blocks a new merge-conductor row for the project (1..86400); the code default is 3600','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.nocap_backoff_s','600','BH-6890: after the hub takes a withdrawn (no-capacity) project row back, it keeps the project this many seconds before it enqueues a new row (1..86400); the code default is 600','seed','2026-10-19T00:00:00Z');
