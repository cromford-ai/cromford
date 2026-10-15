-- BH-6885 (BH-6881.7): the lane-run fleet starts several machines per tick,
-- sized by queued work, and a machine's claim prefers the projects it has warm
-- clones of. Settings seeds only: no new table. D1 is SQLite, not Supabase: RLS
-- does not apply. INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is
-- a no-op and an operator's value is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_fleet.target_drain_s','60','BH-6885: seconds bin/lane-fleet.sh sizes the fleet to drain the queued work in; desired machines = ceil(sum of queued rows x the lane p50 run seconds / this) (10..3600); the code default is 60','seed','2026-10-15T00:00:00Z'),
  ('lane_fleet.max_starts_per_tick','5','BH-6885: machines bin/lane-fleet.sh starts at most in one tick (1..50); the code default is 5','seed','2026-10-15T00:00:00Z'),
  ('lane_run.prefer_max_wait_s','60','BH-6885: seconds a queued lane run may wait before a claim takes it ahead of a machine''s preferred projects (0..3600, 0 = no preference); the code default is 60','seed','2026-10-15T00:00:00Z'),
  ('lane_run.clone_cache_n','8','BH-6885: repo clones bin/lane-run-worker.sh keeps in REPOS_ROOT on a lane-run machine, least recently used out (1..64); the code default is 8','seed','2026-10-15T00:00:00Z');
