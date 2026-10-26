-- ── BH-7934.2 (#7949): the onboarding runner routes' settings rows ─────────
-- Read by src/routes/onboarding-runner.js through the cached settings reader.
-- A missing row or a value that is not an integer in range falls back to the
-- code default of the same value (LIST_MAX_DEF, EXCERPT_MAX_DEF).
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.log_excerpt_max_bytes','4096','BH-7934.2: bytes of a step log_excerpt the beat route keeps (the tail, cut on a UTF-8 boundary). Code default 4096','seed','2026-10-23T05:46:00Z'),
  ('onboarding.list_limit_max','20','BH-7934.2: the largest limit GET /api/onboarding/runs accepts. Code default 20','seed','2026-10-23T05:46:00Z');
