// Frozen baseline: CREATED_TABLE_OVERRIDES.risk_tiers, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5022 — the self-create copy of schema.sql's risk_tiers block, column for
  // column (test/risk-tiers.bh-5022.test.js pins the parity). One row per
  // classified head; the first classification of a head is kept (the route's
  // ON CONFLICT DO NOTHING), because a head's diff never changes.
  risk_tiers: [
    `CREATE TABLE IF NOT EXISTS risk_tiers (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       project TEXT,
       tier TEXT NOT NULL,
       mode TEXT NOT NULL,
       action TEXT,
       reasons TEXT,
       lines INTEGER,
       files INTEGER,
       created_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_risk_tiers_repo_pr ON risk_tiers(repo, pr)",
    "CREATE INDEX IF NOT EXISTS idx_risk_tiers_tier ON risk_tiers(tier, id)",
  ],
};
