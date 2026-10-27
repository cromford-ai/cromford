-- ── BH-8079: the project-21 check knobs as settings rows ───────────────────────
-- Read through lib_env_apply project-21 (bin/lib/project-21.example project-21_knobs) and
-- lane_env_apply project-21-daily (bin/project-21-daily.sh), row first, then env,
-- then the code fallback (the values below; catalog/lanes.d/_lib.project-21.json
-- and catalog/lanes.d/project-21-daily.json are the registry).
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.project-21.project-21_enabled','1','BH-8079: 1 = every build checks its lockfiles with project-21 once after the push; 0 = no call and no PR section','seed','2026-10-23T00:00:00Z'),
  ('lib.project-21.project-21_review_block','0','BH-8079: 1 = the project-21-upgrade self-check rule refuses (holds the lead review); 0 = a NOTE','seed','2026-10-23T00:00:00Z'),
  ('lib.project-21.project-21_timeout_s','30','BH-8079: curl --max-time of the one project-21 request, seconds','seed','2026-10-23T00:00:00Z'),
  ('lib.project-21.project-21_rows_max','50','BH-8079: the most affected rows and skip lines in the PR body section','seed','2026-10-23T00:00:00Z'),
  ('lib.project-21.project-21_field_max','200','BH-8079: the most characters of one field in the PR body section','seed','2026-10-23T00:00:00Z'),
  ('lib.project-21.project-21_note_max','10','BH-8079: the most project-21-upgrade lines one self-check prints','seed','2026-10-23T00:00:00Z'),
  ('lane.project-21-daily.project-21_daily_fail_pct','50','BH-8079: the daily lane alerts when more than this percent of the window''s builds failed the project-21 check','seed','2026-10-23T00:00:00Z'),
  ('lane.project-21-daily.project-21_daily_window_h','24','BH-8079: the hours of builds the daily project-21 lane counts','seed','2026-10-23T00:00:00Z');
