-- ── BH-6939 (rest of #6882): the issue the 24 h hub load baseline goes to ───
-- Read by bin/hub-load-baseline.sh through setting_get. A value that is not a
-- positive integer is ignored and the code default (6881) is used.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hub_load.baseline_issue','6881','BH-6939: the issue that gets the one 24 h hub load baseline comment (bin/hub-load-baseline.sh)','seed','2026-10-15T00:00:00Z');
