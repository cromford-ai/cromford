-- ── stage.archie-card: the BH-8817 Archie card stage route ──────────────────
-- The BH-2536 rule: every agent-call stage has a hub rung-0 stage.<x> route
-- (tests/stage-route-seed.bh-2536-test.sh R1). bin/archie-cards.sh calls
-- agent-call.sh on stage archie-card, and agent-call.sh picks its runner from
-- stage.archie-card; BH-8817 seeded no row, so main went red on R1. The row is
-- copied from stage.execute rung 0 on the claude runner, as stage.archie and
-- stage.unblock are, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.archie-card', 0, m.model, m.runner, 'seed', '2026-11-04T21:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.archie-card')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.archie-card');
