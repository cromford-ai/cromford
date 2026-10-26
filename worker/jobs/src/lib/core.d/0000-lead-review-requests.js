// Frozen baseline: CREATED_TABLE_OVERRIDES.lead_review_requests, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1949 — the self-create copy of schema.sql's lead_review_requests block
  // (BH-1948), column for column; test/lead-reviews.bh-1949.test.js pins the
  // parity. No triggers: unlike verdicts, a request row moves through claim,
  // result and promotion.
  lead_review_requests: [
    `CREATE TABLE IF NOT EXISTS lead_review_requests (
       id TEXT PRIMARY KEY,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       scope_notes TEXT,
       prior_verdict_ref TEXT,
       requested_by TEXT,
       status TEXT NOT NULL DEFAULT 'requested',
       job_id TEXT,
       box TEXT,
       verdict TEXT,
       report_ref TEXT,
       reviewer_model TEXT,
       detail TEXT,
       promoted_verdict_at TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_lead_review_requests_status ON lead_review_requests(status, repo)",
  ],
};
