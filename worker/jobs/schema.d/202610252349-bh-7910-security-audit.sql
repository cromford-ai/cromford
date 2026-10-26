-- ── BH-7910: the security audit runner's caps and its stage.audit route ──────
-- bin/security-audit.sh reads security_audit.cap_usd and
-- security_audit.cap_minutes through setting_get; a --cap-* flag wins, and
-- catalog/security-audit.conf is the fallback when the row is absent.
-- The stage.audit route (the BH-2536 rule: every agent-call stage has a hub
-- rung-0 stage.<x> route) is copied from stage.execute rung 0, the way
-- stage.unblock is, so no model literal enters. The NOT EXISTS guards keep an
-- operator's cut: a role with a model_route_changes row is never put back.
-- No table is created here. INSERT OR IGNORE: a re-apply changes nothing.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('security_audit.cap_usd','60','BH-7910: the dollar cap of one bin/security-audit.sh run. The runner stops the session at this spend and keeps the partial findings.','seed','2026-10-22T08:01:00Z'),
  ('security_audit.cap_minutes','240','BH-7910: the wall-clock cap, in minutes, of one bin/security-audit.sh run.','seed','2026-10-22T08:01:00Z');
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.audit', 0, m.model, m.runner, 'seed', '2026-10-22T08:01:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.audit')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.audit');
