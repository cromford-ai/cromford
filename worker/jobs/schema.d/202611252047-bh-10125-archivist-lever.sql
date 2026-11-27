-- ── BH-10125: the archivist staff agent's repeat rule (C4 of #9423) ────────────
-- bin/staff/archivist-lever.sh (hourly, hub) reads Archie's hand-fix log
-- (archie_actions, through the BH-4587 reader and cause fingerprint) and counts
-- causes_fixed_by_hand_twice: the distinct causes with at least
-- recur_n occurrences (row below) in the last window_days (row below)
-- UTC days. At staff.archivist.level = file or act it files ONE ai-build issue
-- per such cause. Fallbacks in the script: recur_n 2, window_days 7 (a value
-- over 30 is one warn line and 7).
-- Note: docs/notes/2026-11-25-BH-10125-archivist.md.
-- no table: settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.archivist.recur_n','2','BH-10125: occurrences of one cause in the window that make it fixed by hand twice. Fallback 2; reader bin/staff/archivist-lever.sh.','seed','2026-11-25T20:47:00Z'),
  ('staff.archivist.window_days','7','BH-10125: the UTC days of archie_actions the archivist counts (1..30). Fallback 7; reader bin/staff/archivist-lever.sh.','seed','2026-11-25T20:47:00Z');
