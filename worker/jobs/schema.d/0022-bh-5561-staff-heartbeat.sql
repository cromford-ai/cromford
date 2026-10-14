-- ── BH-5561 (BH-5556.4): the staff heartbeat's route seed ───────────────────
-- bin/staff.sh tick <name> calls agent-call with the ONE stage staff-tick for
-- every staff agent (the operator, 2026-10-12), so it reads ONE route,
-- stage.staff-tick. The agent rides as STAFF_AGENT and in AGENT_CALL_FP.
-- Per-agent routing is a later ticket. The NOT EXISTS guards keep an
-- operator's cut: a role with a model_route_changes row is never put back.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table. INSERT OR
-- IGNORE seeds only, so a re-apply through bin/harness-sync.sh is a no-op.
-- Copied from triage rung 0 on the claude runner, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.staff-tick', 0, m.model, m.runner, 'seed', '2026-10-12T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.staff-tick')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.staff-tick');
