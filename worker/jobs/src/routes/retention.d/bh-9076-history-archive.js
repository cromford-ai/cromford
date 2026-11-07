// BH-9076 (slice 5 of BH-9067): history and money tables that had no
// retention rule. Each rule MOVES a row older than its window to the archive
// D1 (lib/archive.js; specs in lib/archive-tables.bh-9076.js): it copies the
// batch, counts it back, and only then deletes it from hot. Money and history
// rows are archived, never only deleted. quietUnbound: with the archive D1
// unbound a rule deletes nothing and reports "archive not bound" only while a
// row waits (the BH-7243.0 pattern).
//
// def is the code fallback of the settings row named in `key`
// (retention.<table>.days, seeded in schema.d/202611070340-bh-9076-retention-indexes.sql);
// a row value of 0 turns the rule off. The window is 180 days unless a reader
// reads further back (route_shadow 400, block_findings 730: see the line above
// each). A rule with a status test repeats it in the delete, so a row that
// went live again between the id read and the delete stays. A time column
// that a client sends (not the worker clock) is also held to >= '2000-01-01',
// so a value that is not an ISO time never reads as old.
// Each id read walks an index on its time column (named in the schema file).
// lane_runs names its index with INDEXED BY: without it the planner takes
// idx_lane_runs_claim (status first) and sorts every finished row.
// The global retention.dry_run (seed 1), retention.max_rows and retention.batch
// apply to every rule here.

export default [
  // flaky_quarantine_changes: quarantine change audit; read: latest N, the daily digest.
  {
    rule: "flaky_quarantine_changes.archive", table: "flaky_quarantine_changes", key: "retention.flaky_quarantine_changes.days", def: 180,
    archive: "flaky_quarantine_changes", quietUnbound: true,
    ids: "SELECT id FROM flaky_quarantine_changes WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM flaky_quarantine_changes WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM flaky_quarantine_changes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // hub_lease_changes: hub lease change audit; read: latest N (routes/hub-recovery.js).
  {
    rule: "hub_lease_changes.archive", table: "hub_lease_changes", key: "retention.hub_lease_changes.days", def: 180,
    archive: "hub_lease_changes", quietUnbound: true,
    ids: "SELECT id FROM hub_lease_changes WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM hub_lease_changes WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM hub_lease_changes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // main_red_events: main-red raise/clear history; no reader in src reads old rows.
  {
    rule: "main_red_events.archive", table: "main_red_events", key: "retention.main_red_events.days", def: 180,
    archive: "main_red_events", quietUnbound: true,
    ids: "SELECT id FROM main_red_events WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM main_red_events WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM main_red_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // registry_seed_runs: registry seed run audit; read: latest N (routes/settings.js); a
  // 'started' run stays.
  {
    rule: "registry_seed_runs.archive", table: "registry_seed_runs", key: "retention.registry_seed_runs.days", def: 180,
    archive: "registry_seed_runs", quietUnbound: true,
    ids: "SELECT id FROM registry_seed_runs WHERE started_at < ?1 AND status IN ('applied','failed') ORDER BY started_at LIMIT ?2",
    sel: "SELECT * FROM registry_seed_runs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM registry_seed_runs WHERE id IN (SELECT value FROM json_each(?1)) AND status IN ('applied','failed')",
  },
  // restore_lab_runs: restore drill results; read: open rows and latest N (routes/restore-
  // lab.js); an open run stays.
  {
    rule: "restore_lab_runs.archive", table: "restore_lab_runs", key: "retention.restore_lab_runs.days", def: 180,
    archive: "restore_lab_runs", quietUnbound: true,
    ids: "SELECT id FROM restore_lab_runs WHERE requested_at < ?1 AND status NOT IN ('requested','claimed') ORDER BY requested_at LIMIT ?2",
    sel: "SELECT * FROM restore_lab_runs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM restore_lab_runs WHERE id IN (SELECT value FROM json_each(?1)) AND status NOT IN ('requested','claimed')",
  },
  // standby_verify_runs: standby verify results; read: open rows and latest N (routes/hub-
  // standby-verify.js); an open run stays.
  {
    rule: "standby_verify_runs.archive", table: "standby_verify_runs", key: "retention.standby_verify_runs.days", def: 180,
    archive: "standby_verify_runs", quietUnbound: true,
    ids: "SELECT id FROM standby_verify_runs WHERE requested_at < ?1 AND status NOT IN ('requested','claimed') ORDER BY requested_at LIMIT ?2",
    sel: "SELECT * FROM standby_verify_runs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM standby_verify_runs WHERE id IN (SELECT value FROM json_each(?1)) AND status NOT IN ('requested','claimed')",
  },
  // box_commands_v2: box command audit (Fly stop/destroy, Orgo controls); the rule is
  // box_command_history.archive because bin/d1-retention.sh skips a rule name with a
  // digit; read: open rows and latest N (routes/box-commands.js); an open command stays.
  {
    rule: "box_command_history.archive", table: "box_commands_v2", key: "retention.box_commands_v2.days", def: 180,
    archive: "box_commands_v2", quietUnbound: true,
    ids: "SELECT id FROM box_commands_v2 WHERE requested_at < ?1 AND status IN ('ok','fail') ORDER BY requested_at LIMIT ?2",
    sel: "SELECT * FROM box_commands_v2 WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM box_commands_v2 WHERE id IN (SELECT value FROM json_each(?1)) AND status IN ('ok','fail')",
  },
  // box_console_commands: console command results; read: by id and the open queue
  // (routes/box-console-commands.js); an open command stays.
  {
    rule: "box_console_commands.archive", table: "box_console_commands", key: "retention.box_console_commands.days", def: 180,
    archive: "box_console_commands", quietUnbound: true,
    ids: "SELECT rowid AS id FROM box_console_commands WHERE created_at < ?1 AND status NOT IN ('queued','claimed') ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM box_console_commands WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM box_console_commands WHERE rowid IN (SELECT value FROM json_each(?1)) AND status NOT IN ('queued','claimed')",
  },
  // cli_versions: CLI update history; read: latest N (routes/cli-versions.js).
  {
    rule: "cli_versions.archive", table: "cli_versions", key: "retention.cli_versions.days", def: 180,
    archive: "cli_versions", quietUnbound: true,
    ids: "SELECT rowid AS id FROM cli_versions WHERE inserted_at < ?1 ORDER BY inserted_at LIMIT ?2",
    sel: "SELECT * FROM cli_versions WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM cli_versions WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // extra_usage_snapshots: account usage polls (money: extra_used_usd); read: the usage
  // windows (5h..7d, lib/account-usage.js) and GET /api/cost ?day=.
  {
    rule: "extra_usage_snapshots.archive", table: "extra_usage_snapshots", key: "retention.extra_usage_snapshots.days", def: 180,
    archive: "extra_usage_snapshots", quietUnbound: true,
    ids: "SELECT rowid AS id FROM extra_usage_snapshots WHERE ts >= '2000-01-01' AND ts < ?1 ORDER BY ts LIMIT ?2",
    sel: "SELECT * FROM extra_usage_snapshots WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM extra_usage_snapshots WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // vendor_spend: vendor meter rows (money); read: since= windows (bin/openrouter-
  // audit.sh, bin/cost-reconcile.sh).
  {
    rule: "vendor_spend.archive", table: "vendor_spend", key: "retention.vendor_spend.days", def: 180,
    archive: "vendor_spend", quietUnbound: true,
    ids: "SELECT rowid AS id FROM vendor_spend WHERE ts >= '2000-01-01' AND ts < ?1 ORDER BY ts LIMIT ?2",
    sel: "SELECT * FROM vendor_spend WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM vendor_spend WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // cost_reconciliation: meter vs rows reconciliation (money); read: since= on window_end
  // (routes/usage.js).
  {
    rule: "cost_reconciliation.archive", table: "cost_reconciliation", key: "retention.cost_reconciliation.days", def: 180,
    archive: "cost_reconciliation", quietUnbound: true,
    ids: "SELECT rowid AS id FROM cost_reconciliation WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM cost_reconciliation WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM cost_reconciliation WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // queue_batch_minutes: merge queue CI minutes (money); read: at most 90 days
  // (routes/queue-batch-minutes.js DAYS_MAX).
  {
    rule: "queue_batch_minutes.archive", table: "queue_batch_minutes", key: "retention.queue_batch_minutes.days", def: 180,
    archive: "queue_batch_minutes", quietUnbound: true,
    ids: "SELECT rowid AS id FROM queue_batch_minutes WHERE closed_at < ?1 ORDER BY closed_at LIMIT ?2",
    sel: "SELECT * FROM queue_batch_minutes WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM queue_batch_minutes WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // ci_batches: CI batch runs with billed minutes (money); read: since= on completed_at
  // (routes/ci-batches.js); a run with no completed_at stays.
  {
    rule: "ci_batches.archive", table: "ci_batches", key: "retention.ci_batches.days", def: 180,
    archive: "ci_batches", quietUnbound: true,
    ids: "SELECT run_id AS id FROM ci_batches WHERE completed_at >= '2000-01-01' AND completed_at < ?1 ORDER BY completed_at LIMIT ?2",
    sel: "SELECT * FROM ci_batches WHERE run_id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM ci_batches WHERE run_id IN (SELECT value FROM json_each(?1))",
  },
  // route_shadow: shadow routing evidence; read: GET /api/route-shadow/bounce days<=365
  // (routes/route-rules.js), so the window is 400.
  {
    rule: "route_shadow.archive", table: "route_shadow", key: "retention.route_shadow.days", def: 400,
    archive: "route_shadow", quietUnbound: true,
    ids: "SELECT id FROM route_shadow WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM route_shadow WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM route_shadow WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // block_findings: classified BLOCK findings (a metered model output); read: lessons
  // before/after windows up to 90+365 days, lessons.retention_days 730
  // (routes/lessons.js), so the window is 730.
  {
    rule: "block_findings.archive", table: "block_findings", key: "retention.block_findings.days", def: 730,
    archive: "block_findings", quietUnbound: true,
    ids: "SELECT id FROM block_findings WHERE verdict_at < ?1 ORDER BY verdict_at LIMIT ?2",
    sel: "SELECT * FROM block_findings WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM block_findings WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // ci_flakes: flake sightings; read: since= on day (routes/flakes.js).
  {
    rule: "ci_flakes.archive", table: "ci_flakes", key: "retention.ci_flakes.days", def: 180,
    archive: "ci_flakes", quietUnbound: true,
    ids: "SELECT rowid AS id FROM ci_flakes WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM ci_flakes WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM ci_flakes WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // outcome_metrics: PR outcomes; read: DORA at most 90+60 days (routes/dora.js), review
  // tiers, latest N.
  {
    rule: "outcome_metrics.archive", table: "outcome_metrics", key: "retention.outcome_metrics.days", def: 180,
    archive: "outcome_metrics", quietUnbound: true,
    ids: "SELECT rowid AS id FROM outcome_metrics WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM outcome_metrics WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM outcome_metrics WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // main_red_pairs: resolved main-red pairs; read: open pairs only (routes/main-red-
  // state.js); an open pair (no resolved_at) stays.
  {
    rule: "main_red_pairs.archive", table: "main_red_pairs", key: "retention.main_red_pairs.days", def: 180,
    archive: "main_red_pairs", quietUnbound: true,
    ids: "SELECT rowid AS id FROM main_red_pairs WHERE resolved_at < ?1 ORDER BY resolved_at LIMIT ?2",
    sel: "SELECT * FROM main_red_pairs WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM main_red_pairs WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // merge_queue_batches: merge queue batches; read: live batches, latest N, archie-factory
  // windows; a live batch (no finished_at) stays.
  {
    rule: "merge_queue_batches.archive", table: "merge_queue_batches", key: "retention.merge_queue_batches.days", def: 180,
    archive: "merge_queue_batches", quietUnbound: true,
    ids: "SELECT rowid AS id FROM merge_queue_batches WHERE finished_at >= '2000-01-01' AND finished_at < ?1 ORDER BY finished_at LIMIT ?2",
    sel: "SELECT * FROM merge_queue_batches WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM merge_queue_batches WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // merge_queue_checks: merge queue check runs; read: by live draft PR, the latest 200 per
  // check for medians.
  {
    rule: "merge_queue_checks.archive", table: "merge_queue_checks", key: "retention.merge_queue_checks.days", def: 180,
    archive: "merge_queue_checks", quietUnbound: true,
    ids: "SELECT rowid AS id FROM merge_queue_checks WHERE finished_at >= '2000-01-01' AND finished_at < ?1 ORDER BY finished_at LIMIT ?2",
    sel: "SELECT * FROM merge_queue_checks WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM merge_queue_checks WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // pauses: pause history; read: live pauses and the daily digest; a live pause (no
  // ended_at) stays.
  {
    rule: "pauses.archive", table: "pauses", key: "retention.pauses.days", def: 180,
    archive: "pauses", quietUnbound: true,
    ids: "SELECT id FROM pauses WHERE created_at < ?1 AND ended_at IS NOT NULL ORDER BY created_at LIMIT ?2",
    sel: "SELECT * FROM pauses WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM pauses WHERE id IN (SELECT value FROM json_each(?1)) AND ended_at IS NOT NULL",
  },
  // lane_runs: finished lane runs (INDEXED BY: the planner picks idx_lane_runs_claim
  // otherwise); read: metrics <= 168 h, latest N, machine costing from costed_until; a
  // queued or claimed run stays.
  {
    rule: "lane_runs.archive", table: "lane_runs", key: "retention.lane_runs.days", def: 180,
    archive: "lane_runs", quietUnbound: true,
    ids: "SELECT id FROM lane_runs INDEXED BY idx_lane_runs_finished_at WHERE finished_at < ?1 AND status IN ('done','died') ORDER BY finished_at LIMIT ?2",
    sel: "SELECT * FROM lane_runs WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM lane_runs WHERE id IN (SELECT value FROM json_each(?1)) AND status IN ('done','died')",
  },
];
