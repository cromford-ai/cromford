-- ── BH-9368: a migration-gate red is WAIT_MIGRATION, not RED_TWICE ─────────
-- Read by bin/merge-conductor.d/bh-9368-migration-gate.sh (_mc_miggate_row,
-- through setting_get), once per red PR per conductor tick.
-- mc.migration_gate_checks.<project>: space-separated check names. When EVERY
-- failing REQUIRED check of an approved head is in the list, the row is
-- WAIT_MIGRATION: no rerun, no strike, no resolver hand-off, one alert per
-- (PR, head), and one gate re-run once production holds the SQL at the head
-- checksum. No row or an empty row = the behaviour before BH-9368 (kill
-- switch: set the row to '').
-- mc.migration_apply_workflow.<project> (a workflow file name) has NO seed row:
-- an automatic production apply is an operator opt-in.
-- No table is created here (D1, not Supabase: no RLS, index or retention rule
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('mc.migration_gate_checks.project-6-os','gate','BH-9368: the migration-ledger gate checks of project-6-os (space separated). Every failing required check in this list = WAIT_MIGRATION, not RED_TWICE. Empty = off. Reader: bin/merge-conductor.d/bh-9368-migration-gate.sh','seed','2026-11-11T02:55:00Z');
