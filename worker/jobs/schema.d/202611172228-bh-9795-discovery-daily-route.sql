-- stage.discovery-daily: the discovery-daily lane's route (BH-9795), copied from
-- the stage.sentry-triage route (position 0, claude runner), so no model literal
-- enters. Guarded like 0014-bh-5620: an operator's route or route change wins.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.discovery-daily', 0, m.model, m.runner, 'seed', '2026-11-17T22:28:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.sentry-triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.discovery-daily')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.discovery-daily');
