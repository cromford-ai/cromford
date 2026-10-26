// Frozen baseline: CREATED_TABLE_OVERRIDES.pool_holds, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  pool_holds: [
    `CREATE TABLE IF NOT EXISTS pool_holds (
       project TEXT NOT NULL,
       kind TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ticket_id TEXT,
       until_at INTEGER,
       why TEXT,
       first_seen TEXT,
       last_seen TEXT,
       box TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, kind, ticket_key)
     )`,
  ],
};
