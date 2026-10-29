-- ── BH-2536 for BH-7261: the stage.pm route ──────────────────────────────────
-- The BH-2536 rule: every agent-call stage has a hub rung-0 stage.<x> route
-- (tests/stage-route-seed.bh-2536-test.sh R1). BH-7261 added the pm-groom site
-- (catalog/llm-sites.d/7261-pm-groom.json, stage pm) and the lane reads the
-- role product.pm (BH-7258). The row is copied from product.pm rung 0, so no
-- model literal enters and the Models page shows the model the call uses. The
-- NOT EXISTS guards keep an operator's cut: a role with a model_route_changes
-- row is never put back. No table is created here. INSERT OR IGNORE: a
-- re-apply changes nothing. #7654 and #8663 carry this fragment byte for byte.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.pm', 0, m.model, m.runner, 'seed', '2026-10-29T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'product.pm' AND m.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.pm')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.pm');
