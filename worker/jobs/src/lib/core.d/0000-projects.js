// Frozen baseline: CREATED_TABLE_OVERRIDES.projects, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-4082: the console's project registry (routes/projects.js), schema.sql's
  // DDL verbatim, self-created for the BH-1043 reason above.
  projects: [
    `CREATE TABLE IF NOT EXISTS projects (
       project TEXT PRIMARY KEY,
       repo TEXT NOT NULL,
       prod_url TEXT,
       board_api_prefix TEXT,
       cron_offset INTEGER NOT NULL,
       box TEXT,
       tailnet_ip TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL)`,
  ],
};
