-- ── BH-7123 wave B: a NEEDS-HUMAN step never gates a merge ───────────────────
-- review.golive_gates_merge: 0 | 1. Read by rl_golive_opt (bin/lib/review-level.sh)
-- through setting_get, `<key>.<project>` first, then `<key>`, then 0.
--   0 = the default. A go-live human step a review names (a live connector key,
--       a vendor console, DNS, a product decision; catalog/review-golive.tsv) is
--       rewritten by rl_cap --golive note to `[HUMAN go-live] <step>` (lead, PR
--       lenses) or `HUMAN_GOLIVE: <step>` (in-build), does not stand as a BLOCK,
--       and rides to the TICKET as a `go-live` hold (bin/needs-human-hold.sh,
--       source go-live): visible on the ticket and the kanban
--       (human-step-waiting), read as CLEAR by bin/fly-pool.sh and
--       bin/blocked-resolver.sh (bin/lib/hold.sh hold:go-live), lifted by a
--       person's HUMAN-STEP-DONE / RESUME. The PR merges on its review.
--   1 = wave A's behaviour: the step stands as a BLOCK and the verdict waits on it.
-- The fix-round cap (review.fix_rounds_max) and the review mode (review.mode) are
-- wave A's rows in 202610161500-bh-7123-review-levels.sql; wave B reads them.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table. INSERT OR
-- IGNORE seeds only, so a re-apply keeps an operator's value.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.golive_gates_merge','0','BH-7123 wave B: 0 = a go-live human step is noted and rides to the ticket as a go-live hold, the PR merges; 1 = it stands as a BLOCK (wave A). Per project: review.golive_gates_merge.<project>','seed','2026-10-16T00:00:00Z');
