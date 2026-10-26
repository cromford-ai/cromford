// Frozen baseline: CREATED_TABLE_OVERRIDES.conflict_hotspot_runs, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  conflict_hotspot_runs: [
    `CREATE TABLE IF NOT EXISTS conflict_hotspot_runs (
       project TEXT PRIMARY KEY,
       repo TEXT,
       box TEXT,
       status TEXT NOT NULL,
       detail TEXT,
       window_days INTEGER,
       since TEXT,
       until TEXT,
       ref_sha TEXT,
       pr_merges INTEGER,
       sync_merges INTEGER,
       merge_tree_errors INTEGER,
       files_total INTEGER,
       rows_stored INTEGER,
       run_at TEXT NOT NULL,
       last_ok_at TEXT
     )`,
  ],
};
