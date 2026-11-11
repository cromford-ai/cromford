-- ── BH-9420: the clerk staff agent's lever window (C2 of #9187) ─────────────
-- bin/staff/clerk-lever.sh (hourly, hub) samples the NEEDS count and, at
-- staff.clerk.level = act with the count at or above staff.clerk.target, runs
-- the #9117 NEEDS sweep at most once per this many hours. The window is the
-- natural key of the lever action (needs-sweep:<window start>), so a second run
-- in one window is the same staff_lever_actions row and runs no second sweep.
-- Fallback 6 in the script (a missing, non-numeric or 0 value).
-- Note: docs/notes/2026-11-10-BH-9420-clerk-lever.md.
-- no table: settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.clerk.lever_every_hours','6','BH-9420: one clerk lever action (a NEEDS sweep run) per this many hours. Fallback 6; reader bin/staff/clerk-lever.sh.','seed','2026-11-10T22:31:00Z');
