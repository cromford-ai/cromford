-- ── BH-9911: the Claude Code CLI pin, its canary and the canary smoke ───────
-- claude_cli_smoke: one row per step of one canary smoke run of one CLI
-- version on one box. Writer: bin/claude-cli-smoke.sh (the canary box, through
-- POST /api/claude-cli/smoke). Readers: the smoke itself (dedup before spend)
-- and bin/claude-cli-pin.sh promote (hub), both through
-- GET /api/claude-cli/smoke?box=&version= (routes/claude-cli-smoke.js).
-- Steps: stdin, late_stdin, tool_call, haiku, lane_tick, fail_classes.
-- Volume: at most ~24 rows a day (4 runs x 6 steps), ~9,000 in 12 months.
-- Indexes:
--   PRIMARY KEY (box, version, run_id, step)  the insert's ON CONFLICT dedup
--   idx_claude_cli_smoke_box_version_at       the GET: WHERE box AND version
--                                             ORDER BY at DESC LIMIT n
--   idx_claude_cli_smoke_inserted_at          the retention id read
-- EXPLAIN QUERY PLAN on 20,000 seeded rows
-- (worker/jobs/test/claude-cli-smoke.bh-9911.test.js R7):
--   GET:       SEARCH claude_cli_smoke USING INDEX idx_claude_cli_smoke_box_version_at (box=? AND version=?)
--   retention: SEARCH claude_cli_smoke USING COVERING INDEX idx_claude_cli_smoke_inserted_at (inserted_at<?)
-- Retention: rule claude_cli_smoke.age (src/routes/retention.d/
-- bh-9911-claude-cli-smoke.js) deletes rows older than
-- retention.claude_cli_smoke.days (90). D1, not Supabase: no RLS applies.
CREATE TABLE IF NOT EXISTS claude_cli_smoke (
  box TEXT NOT NULL,
  version TEXT NOT NULL,
  run_id TEXT NOT NULL,
  step TEXT NOT NULL,
  ok INTEGER NOT NULL,
  rc INTEGER,
  ms INTEGER,
  detail TEXT,
  at TEXT NOT NULL,
  inserted_at TEXT NOT NULL,
  PRIMARY KEY (box, version, run_id, step)
);
CREATE INDEX IF NOT EXISTS idx_claude_cli_smoke_box_version_at ON claude_cli_smoke (box, version, at);
CREATE INDEX IF NOT EXISTS idx_claude_cli_smoke_inserted_at ON claude_cli_smoke (inserted_at);

-- The knobs (bin/lib/claude-cli-pin.sh reads each with setting_get; each code
-- fallback there equals the value seeded here). claude_cli.canary_version has
-- no seed: there is no canary until bin/claude-cli-pin.sh watch finds a
-- release. INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('claude_cli.pin.enabled','0','BH-9911: 1 = every box, the pool image and bootstrap install exactly claude_cli.pinned_version (the canary box: claude_cli.canary_version); 0 = claude goes to latest daily, as before','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.pinned_version','2.1.330','BH-9911: the Claude Code CLI version the fleet runs while claude_cli.pin.enabled=1; bin/claude-cli-pin.sh promote moves it after a green canary soak','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.canary_box','box-small','BH-9911: the one box that installs claude_cli.canary_version and runs bin/claude-cli-smoke.sh (matched after one leading box-; never the hub)','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.canary_soak_h','24','BH-9911: hours a complete green canary smoke run must be old before promote sets the pin','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.smoke_interval_h','6','BH-9911: hours between two canary smoke runs of one version (dedup before spend)','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.smoke_late_stdin_s','5','BH-9911: seconds the late_stdin smoke step holds stdin back (2.1.317 broke at 3 s)','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.smoke_step_timeout_s','120','BH-9911: seconds one smoke step (one agent-call) may run','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.fail_class_window_h','168','BH-9911: at most this many hours of logs/failovers.log before and after the canary install are compared for a new RUNNER_* failure class','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.watch_timeout_s','60','BH-9911: seconds bin/claude-cli-pin.sh watch waits for npm view','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.drift_max_age_h','48','BH-9911: a box_status cli_version older than this many hours is not judged by the drift check','seed','2026-11-23T12:20:00Z'),
  ('claude_cli.smoke_list_limit','200','BH-9911: rows of one (box, version) the smoke and promote read back','seed','2026-11-23T12:20:00Z'),
  ('lane.claude-cli-smoke.llm_usd_cap_day','1','BH-9911: dollars the canary smoke lane may spend a UTC day (about 4 runs x 4 Haiku-class calls)','seed','2026-11-23T12:20:00Z'),
  ('retention.claude_cli_smoke.days','90','BH-9911: days a claude_cli_smoke row is kept (0 = off); a row is the evidence of one canary soak','seed','2026-11-23T12:20:00Z');

-- The smoke's model route: a copy of bootstrap.smoke rung 0 on the claude
-- runner (a Haiku-class model), so no model literal enters (the BH-9125
-- pattern). The two NOT EXISTS guards keep an operator's edit or delete.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'claude-cli.smoke', 0, m.model, m.runner, 'seed', '2026-11-23T12:20:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'bootstrap.smoke' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'claude-cli.smoke')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'claude-cli.smoke');
