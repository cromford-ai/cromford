// Frozen baseline: CREATED_TABLE_OVERRIDES.suite_results, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5354.0 (BH-5366) — the suite ledger (routes/suite-results.js).
  // schema.sql's DDL verbatim, self-created for the BH-1043 reason above;
  // test/suite-results-schema.bh-5366.test.js compares the two.
  suite_results: [
    `CREATE TABLE IF NOT EXISTS suite_results (
       repo TEXT NOT NULL,
       ctx TEXT NOT NULL,
       class TEXT NOT NULL,
       suite TEXT NOT NULL,
       fingerprint TEXT NOT NULL,
       status TEXT NOT NULL,
       duration_s INTEGER,
       run_id TEXT NOT NULL,
       head_sha TEXT,
       ok_at TEXT,
       last_run_id TEXT NOT NULL,
       runs INTEGER NOT NULL DEFAULT 1,
       fails INTEGER NOT NULL DEFAULT 0,
       first_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, ctx, class, suite, fingerprint)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_suite_results_updated ON suite_results(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_suite_results_key ON suite_results(repo, ctx, suite, fingerprint)",
  ],
};
