-- ── BH-7258 (BH-7244.1): the PM agent's route seed ──────────────────────────
-- The PM agent stages (BH-7244.3 / BH-7244.4) read ONE role, product.pm, with
-- `lane_model PM_MODEL product.pm`. No route is no call. The NOT EXISTS guards
-- keep an operator's cut: a role with a model_route_changes row is never put
-- back. D1 is SQLite, not Supabase: RLS does not apply. No new table. INSERT
-- OR IGNORE seeds only, so a re-apply through bin/harness-sync.sh is a no-op.
-- Copied from product.prd rung 0, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'product.pm', 0, m.model, m.runner, 'seed', '2026-10-17T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'product.prd' AND m.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'product.pm')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'product.pm');
