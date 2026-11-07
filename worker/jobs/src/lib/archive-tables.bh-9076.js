// BH-9076 (slice 5 of BH-9067): the archive specs of the history and money
// tables that routes/retention.d/bh-9076-history-archive.js moves to the
// archive D1. lib/archive.js spreads this object into ARCHIVE_TABLES. `key` is
// the hot table's primary key or unique key (the archive table's primary key),
// `time` the column the rule's id read compares to its cutoff (the archive
// table gets an index on it).
export const BH9076_ARCHIVE_TABLES = {
  flaky_quarantine_changes: { key: ["id"], time: "at" },
  hub_lease_changes: { key: ["id"], time: "at" },
  main_red_events: { key: ["id"], time: "at" },
  registry_seed_runs: { key: ["id"], time: "started_at" },
  restore_lab_runs: { key: ["id"], time: "requested_at" },
  standby_verify_runs: { key: ["id"], time: "requested_at" },
  box_commands_v2: { key: ["id"], time: "requested_at" },
  box_console_commands: { key: ["command_id"], time: "created_at" },
  cli_versions: { key: ["box", "cli", "at", "source"], time: "inserted_at" },
  extra_usage_snapshots: { key: ["box", "ts"], time: "ts" },
  vendor_spend: { key: ["vendor", "ts"], time: "ts" },
  cost_reconciliation: { key: ["account", "window_key", "window_end"], time: "created_at" },
  queue_batch_minutes: { key: ["repo", "draft_pr", "run_id"], time: "closed_at" },
  ci_batches: { key: ["run_id"], time: "completed_at" },
  route_shadow: { key: ["id"], time: "at" },
  block_findings: { key: ["id"], time: "verdict_at" },
  ci_flakes: { key: ["repo", "workflow", "test", "head"], time: "created_at" },
  outcome_metrics: { key: ["repo", "pr", "outcome"], time: "created_at" },
  main_red_pairs: { key: ["repo", "hash", "opened_at"], time: "resolved_at" },
  merge_queue_batches: { key: ["repo", "draft_pr"], time: "finished_at" },
  merge_queue_checks: { key: ["repo", "draft_pr", "name"], time: "finished_at" },
  pauses: { key: ["id"], time: "created_at" },
  lane_runs: { key: ["id"], time: "finished_at" },
};
