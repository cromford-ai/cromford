// Frozen baseline: CREATED_TABLE_OVERRIDES.suite_reuse_runs, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  suite_reuse_runs: [
    `CREATE TABLE IF NOT EXISTS suite_reuse_runs (
       repo TEXT NOT NULL,
       run_key TEXT NOT NULL,
       ctx TEXT NOT NULL,
       class TEXT NOT NULL,
       head_sha TEXT,
       ran INTEGER NOT NULL,
       reused INTEGER NOT NULL,
       total INTEGER NOT NULL,
       saved_s INTEGER NOT NULL DEFAULT 0,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, run_key)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_suite_reuse_runs_created ON suite_reuse_runs(created_at)",
  ],
};
