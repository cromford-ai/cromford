-- ── BH-6882 (part of #6881): the hub load sampler's two operator knobs ───────
-- Read by bin/hub-load-sample.sh through setting_get. A value that is not a
-- positive integer is ignored and the code default (the value below) is used.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hub_load.keep_days','14','BH-6882: days of state/hub-load/<date>.tsv files the hub load sampler keeps (by the date in the filename)','seed','2026-10-15T00:00:00Z'),
  ('hub_load.max_runnable','8','BH-6882: runnable processes; one ALERTS line per UTC hour when the p90 of the last 6 hub load samples is over this','seed','2026-10-15T00:00:00Z');
