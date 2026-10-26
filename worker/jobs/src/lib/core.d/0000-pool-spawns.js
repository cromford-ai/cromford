// Frozen baseline: CREATED_TABLE_OVERRIDES.pool_spawns, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5001 — the Fly pool's spawn ledger, terminal verdicts and holds
  // (routes/pool-state.js). schema.sql's DDL verbatim, self-created for the
  // BH-1043 reason above; test/pool-state.bh-5001.test.js compares the columns.
  pool_spawns: [
    `CREATE TABLE IF NOT EXISTS pool_spawns (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ts INTEGER NOT NULL,
       box TEXT NOT NULL,
       machine TEXT,
       created_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key, ts, box)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_pool_spawns_ts ON pool_spawns(project, ts)",
  ],
};
