// Frozen baseline: CREATED_TABLE_OVERRIDES.merge_trains, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1269 — the merge-train registry. Same reason as every self-created table:
  // the deploy is `wrangler deploy`, so a table that waits for a hand-run
  // `d1 execute` ships dead and bin/batch-resolve.sh's row write fails open
  // silently, which is indistinguishable from a lane that ran no trains.
  merge_trains: [
    `CREATE TABLE IF NOT EXISTS merge_trains (
       project TEXT NOT NULL,
       branch TEXT NOT NULL,
       repo TEXT,
       train_pr INTEGER,
       members TEXT,
       member_count INTEGER,
       union_sha TEXT,
       run_id TEXT,
       train_group TEXT,
       outcome TEXT NOT NULL,
       merge_sha TEXT,
       detail TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, branch)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_merge_trains_outcome ON merge_trains(outcome, project, created_at)",
  ],
};
