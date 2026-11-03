-- ── BH-8704: the migration lane knobs as settings rows ─────────────────────
-- Read through lane_env_apply migration <project> (bin/migration-lane.sh):
-- lane.migration.<project>.<knob> first, then lane.migration.<knob>, then the
-- code fallback in bin/lib/migration-lane.sh (the values below;
-- catalog/lanes.d/migration.json is the registry).
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.migration.batch_max','6','BH-8704: ready migration PRs one batch may carry','seed','2026-10-28T00:00:00Z'),
  ('lane.migration.ci_timeout_s','3600','BH-8704: seconds the lane waits for the batch CI before it closes the batch and alerts','seed','2026-10-28T00:00:00Z'),
  ('lane.migration.ci_poll_s','60','BH-8704: seconds between two CI reads of the batch head','seed','2026-10-28T00:00:00Z'),
  ('lane.migration.lease_ttl_s','900','BH-8704: project lease TTL the lane asks for, renewed on every poll','seed','2026-10-28T00:00:00Z'),
  ('lane.migration.setup_timeout_s','900','BH-8704: wall time of MIGRATION_LANE_SETUP_CMD in the apply tree','seed','2026-10-28T00:00:00Z'),
  ('lane.migration.apply_timeout_s','1800','BH-8704: wall time of MIGRATION_LANE_APPLY_CMD, the project migration ledger CLI','seed','2026-10-28T00:00:00Z');
