-- BH-7941: the lead review's E2E ratchet. bin/lib/review-level.sh reads
-- review.e2e_ratchet through rl_knob (rl_e2e_ratchet_on): 1 = in the lead
-- lens, an E2E finding that says the spec is red on main too, or that asks
-- for "N full runs" / a per-spec table, is a [NOTE], not a BLOCK; 0 = off,
-- and the `## Main E2E` section says `off`. bin/lib/e2e-main-baseline.sh
-- reads the other five rows (the limits of its GitHub REST reads, one review):
--   review.e2e_baseline_runs       completed runs per list read (per_page, 1-100)
--   review.e2e_baseline_jobs       failed-job logs read per review
--   review.e2e_baseline_ids        failing spec ids kept per run
--   review.e2e_baseline_timeout_s  seconds per REST call
--   review.e2e_baseline_calls      REST calls per review
-- A project row is <key>.<project> and wins over the fleet row. The code
-- fallbacks equal these values. Data only: no new table, so no index, no RLS
-- and no retention rule apply (D1 is SQLite). INSERT OR IGNORE keeps an
-- operator's value.
-- Rollback: set review.e2e_ratchet to 0; the lead review blocks on E2E as
-- before this change.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.e2e_ratchet','1','BH-7941: 1 = lead review E2E ratchet on (a red-on-main E2E finding or a "3 full runs / per-spec table" ask is a NOTE); 0 = off','seed','2026-10-23T00:00:00Z'),
  ('review.e2e_baseline_runs','50','BH-7941: completed Actions runs per list the ## Main E2E section reads (per_page, 1-100)','seed','2026-10-23T00:00:00Z'),
  ('review.e2e_baseline_jobs','2','BH-7941: failed-job logs the ## Main E2E section reads per review','seed','2026-10-23T00:00:00Z'),
  ('review.e2e_baseline_ids','30','BH-7941: failing spec ids kept per run in the ## Main E2E section','seed','2026-10-23T00:00:00Z'),
  ('review.e2e_baseline_timeout_s','15','BH-7941: seconds per GitHub REST call of the ## Main E2E section','seed','2026-10-23T00:00:00Z'),
  ('review.e2e_baseline_calls','6','BH-7941: GitHub REST calls per review for the ## Main E2E section','seed','2026-10-23T00:00:00Z');
