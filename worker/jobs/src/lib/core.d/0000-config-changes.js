// Frozen baseline: CREATED_TABLE_OVERRIDES.config_changes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-2513: the console-controls audit trail (schema.sql carries the same statements).
  config_changes: [
    `CREATE TABLE IF NOT EXISTS config_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       kind TEXT NOT NULL,
       name TEXT NOT NULL,
       before_json TEXT,
       after_json TEXT NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_config_changes_kind_name ON config_changes(kind, name, id)",
  ],
};
