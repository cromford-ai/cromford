-- BH-9068: stage.plan rank 0 is a copy of the plan role's rank 0 (the fleet's
-- Opus rung) and stage.preplan rank 0 a copy of triage.light's rank 0 (the
-- fleet's Sonnet rung). The 0002 stage seed no longer carries a rank 0 for
-- either role; it was the Fable rung, at $10 per million prompt tokens. Rank 1
-- (0002) does not change.
--
-- NO NEW MODEL LITERAL. Every stage.* seed model is copied from a non-stage seed
-- row of the same runner (runner-routes.bh-1766 S4), like stage.plan.child in
-- 0002, so a model-watch upgrade of the twin reaches the stage rung.
--
-- seed-only: fresh-db
-- ADDITIVE ONLY (tests/schema-additive.bh-1000-test.sh): this file never moves
-- a rung that exists. A live DB keeps its rank 0 until the owner's audited
-- PUT /api/model-routes/<role> moves it (plan T1.2). Tombstone-guarded like
-- stage.plan.child: a role with any model_route_changes row is the operator's,
-- so a re-apply never puts back a rung an operator cut.
-- Serving indexes: idx_model_routes_key (coalesce(project,''), role, position)
-- for the twin reads and the position-0 NOT EXISTS; idx_model_route_changes_role
-- (role, project, at) for the audit NOT EXISTS.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.plan', 0, m.model, m.runner, 'seed', '2026-11-05T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'plan' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.plan' AND x.position = 0)
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.plan');
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.preplan', 0, m.model, m.runner, 'seed', '2026-11-05T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage.light' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.preplan' AND x.position = 0)
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.preplan');
