-- ── BH-7398: open PRs join the migration-number check ───────────────────────
-- Read by bin/lib/migration-renumber.sh (mnr_conf) through setting_get, in
-- mc_rebase, the pool rebase (bin/lib/rebase-job.sh) and the builder's pre-PR
-- step. An env value (MNR_OPEN_PRS / MNR_OPEN_PRS_MAX) overrides them; a
-- `.<project>` row wins over the bare key for open_prs. No open_prs row = off.
-- No table is created here (D1, not Supabase: no RLS applies).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('migration_renumber.open_prs.project-6-os','1','BH-7398: 1 = the migrations other open PRs added are taken too (pre-PR: every open PR; at rebase: only a lower PR number). Else off: main only.','seed','2026-10-18T20:40:00Z'),
  ('migration_renumber.open_prs_max','200','BH-7398: how many open PRs the migration-number check reads (one paged REST list per check). 1..1000; another value reads as 200.','seed','2026-10-18T20:40:00Z');
