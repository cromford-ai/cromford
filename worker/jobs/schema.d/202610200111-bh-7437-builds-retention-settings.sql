-- ── BH-7437 part 2: the builds/ retention lane's settings ───────────────────
-- Read by bin/builds-retention.sh through setting_get. A missing row, an
-- outage or a bad value falls back to the code default, named in the run line.
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply. dry_run seeds 1: the first
-- runs only list (logs/builds-retention-dryrun.txt); an operator sets it to 0
-- after reading one list.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('builds_retention.window_days','14','BH-7437: days; a settled build-dir group older than this (plus one day) moves from builds/ to builds-archive/. Code default 14','seed','2026-10-19T15:10:00Z'),
  ('builds_retention.dry_run','1','BH-7437: 1 = builds-retention only lists what it would move (logs/builds-retention-dryrun.txt); 0 = it moves. Code default 1','seed','2026-10-19T15:10:00Z'),
  ('builds_retention.max_dirs','2000','BH-7437: dirs moved per builds-retention run; the run stops between groups (capped=1) and the next day drains the rest. Code default 2000','seed','2026-10-19T15:10:00Z');
