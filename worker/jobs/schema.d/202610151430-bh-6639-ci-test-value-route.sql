-- ── BH-6639 (BH-6618.3): the CI test value model pass's route seed ─────────
-- bin/lib/ci-test-value/model.sh (ctv_model_pass) calls agent-call with the
-- ONE stage ci-test-value for the rows no rule decides, so it reads ONE route,
-- stage.ci-test-value. No route is no call. The NOT EXISTS guards keep an
-- operator's cut: a role with a model_route_changes row is never put back.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table. INSERT OR
-- IGNORE seeds only, so a re-apply through bin/harness-sync.sh is a no-op.
-- Copied from triage rung 0 on the claude runner, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.ci-test-value', 0, m.model, m.runner, 'seed', '2026-10-15T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.ci-test-value')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.ci-test-value');
