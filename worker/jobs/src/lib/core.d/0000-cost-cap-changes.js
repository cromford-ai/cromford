// Frozen baseline: CREATED_TABLE_OVERRIDES.cost_cap_changes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-2563: the cost-cap audit trail (schema.sql carries the same statements).
  cost_cap_changes: [
    `CREATE TABLE IF NOT EXISTS cost_cap_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       key TEXT NOT NULL,
       before_value TEXT,
       after_value TEXT NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_cost_cap_changes_key ON cost_cap_changes(key, at)",
  ],
};
