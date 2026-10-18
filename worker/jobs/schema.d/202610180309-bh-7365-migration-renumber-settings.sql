-- ── BH-7365: which project numbers its migrations by hand ───────────────────
-- Read by bin/lib/migration-renumber.sh (mnr_conf) through setting_get, in
-- mc_rebase, the pool rebase (bin/lib/rebase-job.sh) and the builder's pre-PR
-- step. An env value (MNR_DIR / MNR_MODE / MNR_LOCK_PREFIX) overrides them; a
-- `.<project>` row wins over the bare key. No row = off for that project.
-- migration_renumber.mode[.<project>] has no seed: no row reads as fix.
-- No table is created here (D1, not Supabase: no RLS applies).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('migration_renumber.dir.project-6-os','prisma/sql','BH-7365: the dir of hand-numbered migrations (NNNN_slug.sql) whose branch-added files are renumbered past main on a collision. Empty or no row = off.','seed','2026-10-18T03:09:00Z'),
  ('migration_renumber.lock_prefix.project-6-os','mk','BH-7365: the advisory lock key of a migration is the integer of the ASCII bytes of <prefix><NNNN>; rewritten with the number. ^[a-z]{1,3}$, empty = no lock rewrite.','seed','2026-10-18T03:09:00Z');
