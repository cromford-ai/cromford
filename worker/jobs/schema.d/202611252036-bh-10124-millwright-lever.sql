-- ── BH-10124: the millwright staff agent's bake re-run cap (C3 of #9423) ────
-- bin/staff/millwright-lever.sh (hourly, hub) samples
-- failed_bakes_and_broken_boxes and, at staff.millwright.level = act, re-runs a
-- failed pool image bake once per bake id (bake-rerun:<project>:<sha12>). Each
-- re-run is one remote Fly build, so the lever writes at most this many action
-- rows per UTC day (the scorecard's actions count). Fallback 2 in the script
-- (a missing, non-numeric or 0 value).
-- Note: docs/notes/2026-11-25-BH-10124-millwright.md.
-- no table: settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.millwright.bake_rerun_max_day','2','BH-10124: at most this many millwright bake re-runs (lever actions) per day. Fallback 2; reader bin/staff/millwright-lever.sh.','seed','2026-11-25T20:36:00Z');
