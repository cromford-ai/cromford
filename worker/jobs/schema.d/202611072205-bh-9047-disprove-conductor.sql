-- ── BH-9047 (C1): the disprove pass on a conductor re-review BLOCK ──────────
-- dpc_run (bin/lib/review-disprove.sh), called by mc_rereview
-- (bin/lib/mc/rebase.sh), gives the pass this many seconds after a re-review
-- BLOCK. Each call still needs review.disprove.min_left_s left. The other
-- review.disprove.* rows (C0) are shared with the lead lane.
--   review.disprove.conductor_left_s  60..3600; code fallback 900.
-- no-index: settings this file adds a row to an existing table, no new table
INSERT OR IGNORE INTO settings (key, value, note, actor, updated_at) VALUES
  ('review.disprove.conductor_left_s','900','BH-9047 C1: seconds the conductor disprove pass may use after a re-review BLOCK; each call still needs review.disprove.min_left_s (60..3600; code fallback 900)','seed','2026-11-07T00:00:00Z');
