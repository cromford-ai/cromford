-- ── BH-9911: the canary smoke's request bounds and step grace as knobs ──────
-- Each row's value equals the code fallback beside its key: the four route
-- bounds in worker/jobs/src/routes/claude-cli-smoke.js (ROWS_MAX, DETAIL_MAX,
-- LIMIT_MAX, LIMIT_DEFAULT) and the two step timeouts in
-- bin/lib/claude-cli-pin.sh (CCP_STEP_GRACE_S_FALLBACK,
-- CCP_STEP_KILL_AFTER_S_FALLBACK), read by bin/claude-cli-smoke.sh, plus three
-- more lib fallbacks: CCP_WATCH_KILL_AFTER_S_FALLBACK (bin/claude-cli-pin.sh
-- watch), CCP_SMOKE_DETAIL_MAX_FALLBACK (the smoke reads the same
-- claude_cli.smoke_detail_max row as the route) and CCP_SMOKE_EXCERPT_MAX_FALLBACK,
-- and three more route bounds: BOX_MAX_LEN, RUN_ID_MAX_LEN, AT_MAX_LEN.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('claude_cli.smoke_post_rows_max','50','BH-9911: most rows one POST /api/claude-cli/smoke may carry (a smoke run writes 6); more is 400 and nothing is written','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_detail_max','500','BH-9911: most characters one smoke row detail may hold; longer is 400 (bin/claude-cli-smoke.sh reads this row and cuts its detail to it)','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_list_limit_max','500','BH-9911: most rows one GET /api/claude-cli/smoke returns, whatever limit= asks for','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_list_limit_default','100','BH-9911: rows GET /api/claude-cli/smoke returns when the request has no usable limit=','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_step_grace_s','30','BH-9911: seconds the outer timeout of one smoke step waits past claude_cli.smoke_step_timeout_s before it sends TERM','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_step_kill_after_s','10','BH-9911: seconds after that TERM before the outer timeout of one smoke step sends KILL','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.watch_kill_after_s','10','BH-9911: seconds after claude_cli.watch_timeout_s before bin/claude-cli-pin.sh watch sends KILL to npm view','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_excerpt_max','200','BH-9911: characters of a smoke step answer or error kept as its excerpt (row detail, RED alert line)','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_box_max_len','128','BH-9911: most characters of box in a smoke row (POST) or box= (GET /api/claude-cli/smoke); longer is 400','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_run_id_max_len','80','BH-9911: most characters of run_id in a smoke row; longer is 400 and nothing is written','seed','2026-11-24T10:00:00Z'),
  ('claude_cli.smoke_at_max_len','40','BH-9911: most characters of at in a smoke row; longer is 400 and nothing is written','seed','2026-11-24T10:00:00Z');

-- stage.claude-cli-smoke: the route of the smoke's agent-call stage (the census
-- row catalog/llm-sites.d/9911-claude-cli-smoke.json names stage
-- claude-cli-smoke, and tests/stage-route-seed.bh-2536-test.sh R1 wants a
-- hub-scope rung 0 for every agent-call stage). The same copy as the
-- claude-cli.smoke role: bootstrap.smoke rung 0 on the claude runner, so no
-- model literal enters. The two NOT EXISTS guards keep an operator's edit.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.claude-cli-smoke', 0, m.model, m.runner, 'seed', '2026-11-24T10:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'bootstrap.smoke' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.claude-cli-smoke')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.claude-cli-smoke');
