-- ── BH-7725 (UNB-3): the stage.unblock route ─────────────────────────────────
-- The BH-2536 rule: every agent-call stage has a hub rung-0 stage.<x> route
-- (tests/stage-route-seed.bh-2536-test.sh R1). The unblock-decide site
-- (bin/lib/unblock/card.sh) reads model_for stage.unblock. The row is copied
-- from stage.execute rung 0, the way stage.break-it and stage.lesson-propose
-- are, so no model literal enters. The NOT EXISTS guards keep an operator's
-- cut: a role with a model_route_changes row is never put back.
-- No table is created here. INSERT OR IGNORE: a re-apply changes nothing.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.unblock', 0, m.model, m.runner, 'seed', '2026-10-21T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.unblock')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.unblock');
