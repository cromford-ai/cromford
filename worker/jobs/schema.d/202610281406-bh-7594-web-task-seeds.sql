-- ── BH-7594: the web-task lane's seeds ──────────────────────────────────────
-- bin/web-task.sh resolves its model with model_env_or_route WEB_TASK_MODEL
-- web-task, so it reads ONE route, role web-task. No route is no call. Copied
-- from triage rung 0 on the claude runner (the BH-6639 template), so no model
-- literal enters; the claude runner is the one agent-call runs with
-- AGENT_CALL_NO_TOOLS=1. The NOT EXISTS guards keep an operator's cut: a role
-- with a model_route_changes row is never put back.
-- The lane runs on Fly only (bin/lib/web-task/route.sh enqueues a lane_runs
-- row when lp_decide says fly), so lane_placement.web-task is seeded fly.
-- No lane.web-task.<project>.allowed_domains row is seeded: empty = refuse.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table, so no index
-- and no retention rule. INSERT OR IGNORE seeds only, so a re-apply through
-- bin/harness-sync.sh is a no-op.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'web-task', 0, m.model, m.runner, 'seed', '2026-10-19T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'web-task')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'web-task');
-- stage.web-task: the agent-call stage's own route (BH-1765), so the runner
-- read and the Models page see this stage (tests/stage-route-seed.bh-2536).
-- The same copy of triage's claude rung 0, the BH-6639 template.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.web-task', 0, m.model, m.runner, 'seed', '2026-10-19T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.web-task')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.web-task');
-- The lane's llm-gate values are settings rows; the registry keeps the
-- BH-2533 defaults (tests/llm-lane-knobs.bh-2533).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.web-task','fly','BH-7594: the web-task lane runs on the lane-run machines only (the image with chromium and the playwright module); any other value makes the build hook answer WEBTASK_FAILED','seed','2026-10-19T00:00:00Z'),
  ('lane.web-task.llm_runner_allowed','claude','BH-7594: the web-task lane reaches only the claude rung; its calls run with AGENT_CALL_NO_TOOLS=1, which every other runner refuses','seed','2026-10-19T00:00:00Z'),
  ('lane.web-task.llm_usd_cap_day','5','BH-7594: dollars the web-task lane may spend per UTC day (bin/lib/llm-gate.sh); bounds a runaway browser loop','seed','2026-10-19T00:00:00Z');
