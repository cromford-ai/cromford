-- ── BH-7123: review strictness scales to user impact ─────────────────────────
-- The review levels (prompts/iron-laws.d/20261016-review-levels.md) and the
-- demoter (bin/lib/review-level.sh rl_cap) read these rows through setting_get,
-- `<key>.<project>` first, then `<key>`, then the code default named here. No
-- deploy changes a threshold: an operator writes the row (bin/jobs-client.sh
-- setting-set <key> <value> "<why>") and config_changes keeps the audit row.
-- review.mode: strict | shadow | levels | cowboy | off.
--   strict  = today's behaviour: every finding the model tags BLOCK stands.
--   shadow  = compute, log `WOULD demote`, change nothing.
--   levels  = the default: a BLOCK stands only with an ALWAYS-BLOCK class
--             (catalog/review-always-block.tsv); everything else is a NOTE and
--             a review with no standing BLOCK approves.
--   cowboy  = levels, plus no fix rounds and no follow-up tickets (wave B
--             reads the two rows below it); the ALWAYS-BLOCK floor stays on.
--   off     = no review verdict gates a merge; green CI merges.
-- review.mode_until: ISO time; a non-default mode past it is flipped back to
-- levels by bin/review-mode-expire.sh (wave B) and announced. Empty = no expiry.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table. INSERT OR
-- IGNORE seeds only, so a re-apply keeps an operator's value.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.mode','levels','BH-7123: strict | shadow | levels | cowboy | off. Per project: review.mode.<project>. Code default levels','seed','2026-10-16T00:00:00Z'),
  ('review.mode_until','','BH-7123: ISO time after which a non-default review.mode (or review.mode.<project>) flips back to levels; empty = never','seed','2026-10-16T00:00:00Z'),
  ('review.perf_block_ms','300','BH-7123: a measured regression on a key screen over this many ms is a BLOCK; under it a NOTE','seed','2026-10-16T00:00:00Z'),
  ('review.perf_block_stmt_pct','20','BH-7123: a DB-statement increase over this percent on a key screen is a BLOCK; under it a NOTE','seed','2026-10-16T00:00:00Z'),
  ('review.fix_rounds_max','2','BH-7123: non-BLOCK fix rounds per ticket before the lane merges with notes (wave B reads it; per project review.fix_rounds_max.<project>)','seed','2026-10-16T00:00:00Z'),
  ('review.followup_min_level','core','BH-7123: the lowest level whose findings may become a follow-up ticket: always | core | never (wave B reads it)','seed','2026-10-16T00:00:00Z'),
  ('review.core_flows.project-6-os','company setup, departments, dashboards, agents, workflows','BH-7123: the core user flows of project-6-os; a diff on one of them is reviewed at core-flow level','seed','2026-10-16T00:00:00Z'),
  ('review.core_flows.project-5','sign-in, scan, report, connect a source, billing','BH-7123: the core user flows of project-5','seed','2026-10-16T00:00:00Z');
