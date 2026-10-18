-- ── BH-6969 (BH-6544.3): outcomes by review tier ─────────────────────────────
-- GET /api/metrics/review-tiers (src/routes/review-tiers.js) reads the reverts
-- recorded since the window start: outcome_metrics WHERE created_at>=?1 AND
-- outcome='reverted' ORDER BY created_at DESC. idx_outcome_day cannot bound it:
-- `day` moves on every weekly re-scan (routes/outcomes.js day=COALESCE(?4, day)),
-- while created_at is set once on insert. No new table, so no retention rule
-- (outcome_metrics keeps its owner's) and no RLS question (D1 is SQLite).
CREATE INDEX IF NOT EXISTS idx_outcome_created ON outcome_metrics(created_at);

-- The margin of the [dora-review-tiers] alert (bin/dora-digest.sh): one line a
-- UTC day when the low or intent tier's 7-day revert rate is more than this
-- over the full tier's. A decimal 0..1. INSERT OR IGNORE: a re-apply never
-- resets a value an operator set.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.tier_revert_margin','0.02','BH-6969: the [dora-review-tiers] alert fires when the low or intent tier''s 7-day revert rate is more than this over the full tier''s (decimal 0..1)','seed','2026-10-17T00:00:00Z');

-- The minimum sample of the same alert: a cohort (and the full cohort) with
-- fewer 7-day merges than this is not compared, so 1 revert in 1 merge never
-- pages. A non-negative integer (bin/lib/pr-health.sh ph_knob).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.tier_revert_min_n','5','BH-6969: the [dora-review-tiers] alert compares a cohort only when it (and the full cohort) has at least this many 7-day merges (integer)','seed','2026-10-18T00:00:00Z');
