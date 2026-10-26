// Frozen baseline: CREATED_TABLE_OVERRIDES.routing_changes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-2010: the routing audit trail (schema.sql carries the same statements).
  routing_changes: [
    `CREATE TABLE IF NOT EXISTS routing_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       project TEXT NOT NULL,
       before_builder TEXT,
       before_pool_app TEXT,
       before_halted INTEGER,
       after_builder TEXT NOT NULL,
       after_pool_app TEXT,
       after_halted INTEGER NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_routing_changes_project ON routing_changes(project, at)",
  ],
};
