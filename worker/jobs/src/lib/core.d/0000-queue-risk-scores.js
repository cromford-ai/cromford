// Frozen baseline: CREATED_TABLE_OVERRIDES.queue_risk_scores, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5430 — the self-create copy of schema.sql's queue_risk_scores block,
  // column for column (test/queue-risk.bh-5430.test.js pins the parity). One
  // row per scored head; a re-score of the same head UPDATES it (the route's
  // insert-then-update), so the badge shows the newest routing.
  queue_risk_scores: [
    `CREATE TABLE IF NOT EXISTS queue_risk_scores (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       project TEXT,
       score INTEGER,
       threshold INTEGER NOT NULL,
       route TEXT NOT NULL,
       mode TEXT NOT NULL,
       reasons TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_repo_pr ON queue_risk_scores(repo, pr)",
    "CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_route ON queue_risk_scores(route, id)",
  ],
};
