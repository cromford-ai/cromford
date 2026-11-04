-- ── BH-8890: a builder APPROVE alone never clears a lead-required repo ─────
-- Read by bin/lib/lead-required.sh lr_required, once per repo per conductor
-- worker. lead_required.<owner>.<name> (lowercase): 1 = the merge conductor
-- holds a READY row in WAIT_LEAD until a lead or human MERGE /
-- MERGE-WITH-NOTES stands on the head, and asks one lead review per head; the
-- conductor publishers post lead-verdict there only on such a row. 0 or no
-- row = the behavior before BH-8890. Kill switch: set the row to 0.
-- No table is created here (D1, not Supabase: no RLS, index or retention rule
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lead_required.example-org.project-6','1','BH-8890: 1 = READY on example-org/project-6 needs a lead or human MERGE on the live head; a builder APPROVE alone is WAIT_LEAD and asks one lead review per head (0..1; no row = 0). Reader: bin/lib/lead-required.sh','seed','2026-11-03T23:42:00Z');
