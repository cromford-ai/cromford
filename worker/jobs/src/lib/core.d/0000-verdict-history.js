// Frozen baseline: CREATED_TABLE_OVERRIDES.verdict_history, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1024 — the append-only verdict record. Same reason as every entry above,
  // and this one is on the HOT path: `job_artifact_put verdict` is how run-build
  // settles, how the BH-1064 block records a review and how
  // `job_verdict_rebind` re-binds an approval after a rebase. A missing table
  // there throws AFTER the standing upsert has landed, so the PUT 500s, the
  // rebind returns rc 1, `mc_rebase` returns rc 5, and a rebased approved PR
  // parks in NEEDS_REBASE "rebind-failed" until somebody hand-runs a d1 execute.
  // Column for column with schema.sql (worker/jobs/test/verdict-history.bh-1024.test.js
  // asserts the agreement, and the pre-deploy database case asserts this map is
  // what creates the table on the live D1).
  verdict_history: [
    `CREATE TABLE IF NOT EXISTS verdict_history (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       job_id TEXT NOT NULL,
       verdict TEXT NOT NULL,
       reviewed_sha TEXT,
       tier TEXT,
       provenance TEXT,
       served_by TEXT,
       source TEXT,
       detail TEXT,
       actor TEXT,
       created_at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_verdict_history_job ON verdict_history(job_id, id)",
  ],
};
