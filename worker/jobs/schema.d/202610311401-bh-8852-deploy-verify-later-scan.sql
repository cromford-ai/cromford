-- ── BH-8852: deploy-verify later-deployment scan size ─────────────────────
-- bin/deploy-verify.sh reads this many recent deployments of the repo when the
-- merge sha has no production deployment of its own (Vercel skipped its build
-- because a newer main commit superseded it). Valid 1..100 (the GitHub
-- per_page max); a missing or invalid row is 10, the code fallback.
-- No table: a settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('deploy.verify.later_deploy_scan','10','BH-8852: how many recent production deployments deploy-verify reads when the merge sha has none of its own (1..100)','seed','2026-10-31T00:00:00Z');
