-- ── BH-7998 (BH-7935.1): the onboarding repos list cap ─────────────────────
-- Read by src/routes/onboarding-repo.js (reposMax) through the cached settings
-- reader. A missing row or a value that is not an integer 1..1000 falls back
-- to the code default of the same value (REPOS_MAX_DEFAULT, 200).
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.repos_list_max','200','BH-7998: the most repo names GET /api/onboarding/repos answers (a cut list is incomplete:true; integer 1..1000). Code default 200','seed','2026-10-27T03:55:00Z');
