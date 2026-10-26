// Frozen baseline: CREATED_TABLE_OVERRIDES.pool_terminals, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  pool_terminals: [
    `CREATE TABLE IF NOT EXISTS pool_terminals (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       branch TEXT,
       head_sha TEXT,
       reason TEXT,
       created_at TEXT NOT NULL,
       box TEXT,
       cleared_at TEXT,
       cleared_why TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key)
     )`,
  ],
};
