-- BH-7520: the hub's merge-conductor publish of a fly-placed project
-- (bin/lib/mc/project-placement.sh, mc_proj_publish). It waits this many
-- seconds for the per-project snapshot lock the cron publisher also takes,
-- and after a failed publish it enqueues a machine row only when the cron
-- publisher's snapshot is fresh enough: age_s + snapshot_margin_s <=
-- lane_snapshot.max_age_s. Otherwise the tick stays on the hub (run 12126
-- got a stale snapshot and ended rc 66). Two knob rows. No new table and no
-- new index: the snapshot read is GET /api/lane-snapshots/<lane>/<project>,
-- a primary-key read. Rollback: publish_lock_wait_s = 10 is the old wait.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('mc_project_fly.publish_lock_wait_s','30','BH-7520: the hub''s write-back apply and snapshot publish for a fly-placed merge-conductor project each wait this many seconds for locks/lane-snapshot-merge-conductor-<project>.lock, which the cron publisher also holds (1..600; any other value reads as 30); the code default is 30','seed','2026-10-19T00:00:00Z'),
  ('mc_project_fly.snapshot_margin_s','300','BH-7520: after a failed hub publish, a fly-placed merge-conductor project gets a machine row only when the current snapshot''s age_s plus this many seconds is at most lane_snapshot.max_age_s; else the tick stays on the hub (1..86400); the code default is 300','seed','2026-10-19T00:00:00Z');
