// Frozen baseline: CREATED_TABLE_OVERRIDES.model_route_changes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  model_route_changes: [
    `CREATE TABLE IF NOT EXISTS model_route_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       scope TEXT NOT NULL,
       project TEXT,
       role TEXT NOT NULL,
       position INTEGER NOT NULL,
       before_model TEXT,
       before_runner TEXT,
       after_model TEXT,
       after_runner TEXT,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_model_route_changes_role ON model_route_changes(role, project, at)",
  ],
};
