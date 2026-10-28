-- ── BH-7931: builds/ retention rule 2 (`settled`) settings ─────────────────
-- Read by bin/builds-retention.sh through setting_get. A missing row, an
-- outage or a bad value falls back to the code default, named in the run line.
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply. builds_retention.dry_run is
-- not seeded here: this ticket does not change it.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('builds_retention.settled_window_days','30','BH-7931: days; an unmerged build-dir group older than this (plus one day) moves when its ticket is closed, or it is superseded or all-terminal. 0 = rule 2 off. Code default 30','seed','2026-10-22T03:30:00Z'),
  ('builds_retention.tracker_reads_max','200','BH-7931: tracker ticket reads per builds-retention run; past it a group is kept as tracker-budget. Code default 200','seed','2026-10-22T03:30:00Z');
