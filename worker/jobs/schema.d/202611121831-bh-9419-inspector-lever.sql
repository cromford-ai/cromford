-- ── BH-9419: the inspector staff agent's metric and lever (C1 of #9187) ────
-- bin/staff/inspector-lever.sh (hourly, hub) samples hours_behind_main (the
-- served-sha-watch state plus the console Pages lag) and, at
-- staff.inspector.level = file or act, files ONE fix-main-red issue per
-- behind episode, with the failing Vercel build step quoted.
-- Each row names its reader and its code fallback.
-- Note: docs/notes/2026-11-12-BH-9419-inspector-lever.md.
-- no table: settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.inspector.lever_dry_run','1','BH-9419: 1 = the fix-main-red lever records a dry action and files no issue; only 0 files. A missing or non-numeric value is dry. Reader bin/staff/inspector-lever.sh, fallback 1.','seed','2026-11-12T18:31:00Z'),
  ('staff.inspector.quote_lines','30','BH-9419: the number of error lines of the failing Vercel build log the fix-main-red issue quotes (the last ones). Reader bin/staff/inspector-lever.sh, fallback 30.','seed','2026-11-12T18:31:00Z'),
  ('staff.inspector.fresh_min','20','BH-9419: minutes; the newest served-sha-watch summary line must be this fresh, else the Vercel part of hours_behind_main is unreadable and no sample is written. Reader bin/staff/inspector-lever.sh, fallback 20.','seed','2026-11-12T18:31:00Z'),
  ('staff.inspector.lever_max_run','1','BH-9419: lever actions (fix-main-red) per inspector run. Reader bin/staff/inspector-lever.sh, fallback 1.','seed','2026-11-12T18:31:00Z'),
  ('staff.inspector.issue_list_max','1000','BH-9419: the most staff:inspector issues (all states) the delivery dedupe reads per run; at most 1000 (the list lib stops at 10 pages). A list that reaches it is list-unreadable and the lever files nothing until the label holds fewer issues or the row is raised. Reader bin/staff/inspector-lever.sh, fallback 1000.','seed','2026-11-12T18:31:00Z'),
  ('staff.inspector.quote_line_chars','300','BH-9419: characters kept of each quoted build-log line (after redaction) in the fix-main-red issue. Reader bin/staff/inspector-lever.sh, fallback 300.','seed','2026-11-12T18:31:00Z');
