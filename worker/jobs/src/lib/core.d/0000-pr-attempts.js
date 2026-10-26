// Frozen baseline: CREATED_TABLE_OVERRIDES.pr_attempts, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  pr_attempts: [
    `CREATE TABLE IF NOT EXISTS pr_attempts (
       repo TEXT NOT NULL, number INTEGER NOT NULL, kind TEXT NOT NULL, sha TEXT NOT NULL,
       at TEXT NOT NULL, actor TEXT,
       PRIMARY KEY (repo, number, kind, sha)
     )`,
  ],
};
