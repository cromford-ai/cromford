-- ── auth.canary: the auth canary's model route (BH-9125, slice C3 of BH-9064) ─
-- Readers: bin/claude-auth-check.sh (the hub PROBE_BODY) and bin/lane-probe.sh
-- (the claude arm, on every box). They buy one inference per account per UTC
-- day to prove the login answers. That needs the cheapest model that can say a
-- word back, not the triage model. The row is a copy of bootstrap.smoke rung 0
-- on the claude runner (a Haiku-class model), so no model literal enters. The
-- two NOT EXISTS guards keep an operator's edit or delete of the route.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'auth.canary', 0, m.model, m.runner, 'seed', '2026-11-06T04:10:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'bootstrap.smoke' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'auth.canary')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'auth.canary');
