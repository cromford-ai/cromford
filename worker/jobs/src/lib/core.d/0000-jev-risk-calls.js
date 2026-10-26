// Frozen baseline: CREATED_TABLE_OVERRIDES.jev_risk_calls, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5024 — the self-create copy of schema.sql's jev_risk_calls block, column
  // for column (test/jev-risk.bh-5024.test.js pins the parity). The spend
  // ledger in front of every Jev call: claimed before, settled after.
  jev_risk_calls: [
    `CREATE TABLE IF NOT EXISTS jev_risk_calls (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       question_version TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('claimed','ok','empty','failed')),
       attempts INTEGER NOT NULL DEFAULT 0,
       rule_tier TEXT,
       jev_tier TEXT,
       jev_prob REAL,
       model TEXT,
       caller TEXT,
       error TEXT,
       raw TEXT,
       claimed_at TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha, question_version)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_jev_risk_repo_pr ON jev_risk_calls(repo, pr)",
  ],
};
