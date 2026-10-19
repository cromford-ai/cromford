-- ── BH-7437 part 1: the lane snapshot publisher's slow-run alert ────────────
-- Read by bin/lane-snapshot-publish.sh through setting_get. A missing,
-- non-number or 0 row falls back to the code default (600), so the row
-- cannot be set to 0. No table is created here (D1, not Supabase: no RLS
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_snapshot.run_alert_s','600','BH-7437: seconds; a lane-snapshot-publish run for one lane longer than this (its 10-min cron period) pages lane-snapshot-slow-<lane> once. 0 or a non-number reads as missing. The code default is 600','seed','2026-10-19T03:00:00Z');
