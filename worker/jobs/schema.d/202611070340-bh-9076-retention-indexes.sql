-- BH-9076 (slice 5 of BH-9067): the windows and the cutoff indexes of the
-- retention rules in worker/jobs/src/routes/retention.d/bh-9076-ops-delete.js
-- (delete) and bh-9076-history-archive.js (move to the archive D1). Additive
-- only: CREATE INDEX IF NOT EXISTS and INSERT OR IGNORE.
--
-- Each rule's id read is `WHERE <time col> < cutoff ORDER BY <time col>`. The
-- indexes below serve that range on every table whose time column had no
-- index with it as the leading column. The other rules read an index that
-- already exists:
--   hub_lease_changes(at) idx_hub_lease_changes_at, registry_seed_runs(started_at)
--   idx_registry_seed_runs_started, extra_usage_snapshots(ts) idx_extra_usage_ts,
--   vendor_spend(ts) idx_vendor_spend_ts, route_shadow(at) idx_route_shadow_at,
--   block_findings(verdict_at) idx_block_findings_at, outcome_metrics(created_at)
--   idx_outcome_created, merge_queue_batches(finished_at) idx_mq_batches_finished.
-- test/retention-rules-explain.bh-9076.test.js R1 runs EXPLAIN QUERY PLAN on
-- every id read and fails on a SCAN of the table or a temp B-tree sort.
-- No index here is on a table with a CREATED_TABLES hand entry
-- (lib/core.d/, test/created-tables.bh-4987.test.js): those tables have a
-- no-retention line (202611070341-bh-9076-no-retention.sql) until the hand
-- entry changes with its index.

CREATE INDEX IF NOT EXISTS idx_ci_duration_runs_posted_at ON ci_duration_runs(posted_at);
CREATE INDEX IF NOT EXISTS idx_flaky_quarantine_changes_at ON flaky_quarantine_changes(at);
CREATE INDEX IF NOT EXISTS idx_main_red_events_at ON main_red_events(at);
CREATE INDEX IF NOT EXISTS idx_restore_lab_runs_requested_at ON restore_lab_runs(requested_at);
CREATE INDEX IF NOT EXISTS idx_standby_verify_runs_requested_at ON standby_verify_runs(requested_at);
CREATE INDEX IF NOT EXISTS idx_box_commands_v2_requested_at ON box_commands_v2(requested_at);
CREATE INDEX IF NOT EXISTS idx_box_console_commands_created_at ON box_console_commands(created_at);
CREATE INDEX IF NOT EXISTS idx_cli_versions_inserted_at ON cli_versions(inserted_at);
CREATE INDEX IF NOT EXISTS idx_cost_reconciliation_created_at ON cost_reconciliation(created_at);
CREATE INDEX IF NOT EXISTS idx_queue_batch_minutes_closed_at ON queue_batch_minutes(closed_at);
CREATE INDEX IF NOT EXISTS idx_ci_batches_completed_at ON ci_batches(completed_at);
CREATE INDEX IF NOT EXISTS idx_ci_flakes_created_at ON ci_flakes(created_at);
CREATE INDEX IF NOT EXISTS idx_main_red_pairs_resolved_at ON main_red_pairs(resolved_at);
CREATE INDEX IF NOT EXISTS idx_merge_queue_checks_finished_at ON merge_queue_checks(finished_at);
CREATE INDEX IF NOT EXISTS idx_pauses_created_at ON pauses(created_at);
CREATE INDEX IF NOT EXISTS idx_lane_runs_finished_at ON lane_runs(finished_at);

-- retention.<table>.days: days a row is kept before its rule acts (0 = the rule
-- is off). The rule's def in code is the fallback for this row.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.ci_duration_runs.days','30','BH-9076: days a ci_duration_runs row is kept; the ci_duration_runs.age retention rule (retention.d/bh-9076-ops-delete.js) DELETES older rows (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.flaky_quarantine_changes.days','180','BH-9076: days a flaky_quarantine_changes row is kept in hot; the flaky_quarantine_changes.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.hub_lease_changes.days','180','BH-9076: days a hub_lease_changes row is kept in hot; the hub_lease_changes.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.main_red_events.days','180','BH-9076: days a main_red_events row is kept in hot; the main_red_events.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.registry_seed_runs.days','180','BH-9076: days a registry_seed_runs row is kept in hot; the registry_seed_runs.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.restore_lab_runs.days','180','BH-9076: days a restore_lab_runs row is kept in hot; the restore_lab_runs.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.standby_verify_runs.days','180','BH-9076: days a standby_verify_runs row is kept in hot; the standby_verify_runs.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.box_commands_v2.days','180','BH-9076: days a box_commands_v2 row is kept in hot; the box_commands_v2.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.box_console_commands.days','180','BH-9076: days a box_console_commands row is kept in hot; the box_console_commands.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.cli_versions.days','180','BH-9076: days a cli_versions row is kept in hot; the cli_versions.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.extra_usage_snapshots.days','180','BH-9076: days a extra_usage_snapshots row is kept in hot; the extra_usage_snapshots.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.vendor_spend.days','180','BH-9076: days a vendor_spend row is kept in hot; the vendor_spend.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.cost_reconciliation.days','180','BH-9076: days a cost_reconciliation row is kept in hot; the cost_reconciliation.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.queue_batch_minutes.days','180','BH-9076: days a queue_batch_minutes row is kept in hot; the queue_batch_minutes.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.ci_batches.days','180','BH-9076: days a ci_batches row is kept in hot; the ci_batches.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.route_shadow.days','400','BH-9076: days a route_shadow row is kept in hot; the route_shadow.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.block_findings.days','730','BH-9076: days a block_findings row is kept in hot; the block_findings.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.ci_flakes.days','180','BH-9076: days a ci_flakes row is kept in hot; the ci_flakes.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.outcome_metrics.days','180','BH-9076: days a outcome_metrics row is kept in hot; the outcome_metrics.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.main_red_pairs.days','180','BH-9076: days a main_red_pairs row is kept in hot; the main_red_pairs.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.merge_queue_batches.days','180','BH-9076: days a merge_queue_batches row is kept in hot; the merge_queue_batches.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.merge_queue_checks.days','180','BH-9076: days a merge_queue_checks row is kept in hot; the merge_queue_checks.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.pauses.days','180','BH-9076: days a pauses row is kept in hot; the pauses.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z'),
  ('retention.lane_runs.days','180','BH-9076: days a lane_runs row is kept in hot; the lane_runs.archive retention rule (retention.d/bh-9076-history-archive.js) MOVES older rows to the archive D1, and deletes nothing while it is unbound (0 = off).','seed','2026-11-07T00:00:00Z');
