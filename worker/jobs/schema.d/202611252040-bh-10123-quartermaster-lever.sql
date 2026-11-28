-- ── BH-10123: the quartermaster staff agent's lever knobs (C2 of #9423) ─────
-- bin/staff/quartermaster-lever.sh (hourly, hub) samples orphan_usd_day: the
-- $/day of started Fly machines with no job row for more than the idle_min
-- row below (minutes), plus the $/day of idle Orgo capacity.
-- At staff.quartermaster.level = act it records ONE staff_lever_actions row per
-- orphan pool machine, then calls bin/fly-idle-reaper.sh act probe (dry) or
-- act stop (lever_dry_run = 0). Each row below has the same fallback in the
-- script. Note: docs/notes/2026-11-25-BH-10123-quartermaster-lever.md.
-- no table: settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.quartermaster.idle_min','60','BH-10123: minutes with no job row before a started Fly machine counts in orphan_usd_day and a pool machine is a lever target. Fallback 60; reader bin/staff/quartermaster-lever.sh.','seed','2026-11-25T20:40:00Z'),
  ('staff.quartermaster.lever_dry_run','1','BH-10123: 1 = dry (record dry-run lever rows and run act probe only); 0 = act stop. Any other value, no row or an outage is dry. Reader bin/staff/quartermaster-lever.sh.','seed','2026-11-25T20:40:00Z'),
  ('staff.quartermaster.stops_max_run','3','BH-10123: the most quartermaster lever actions (and reaper calls) per run. Fallback 3; reader bin/staff/quartermaster-lever.sh.','seed','2026-11-25T20:40:00Z'),
  ('staff.quartermaster.snapshot_max_age_min','30','BH-10123: a GET /api/fly-idle snapshot older than this many minutes is unreadable: no sample, no action. Fallback 30; reader bin/staff/quartermaster-lever.sh.','seed','2026-11-25T20:40:00Z'),
  ('staff.quartermaster.act_timeout_s','180','BH-10123: the timeout in seconds around one bin/fly-idle-reaper.sh act call (the reaper lock wait is 60 s). Fallback 180; reader bin/staff/quartermaster-lever.sh.','seed','2026-11-25T20:40:00Z');
