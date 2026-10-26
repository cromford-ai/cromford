// Frozen baseline: CREATED_TABLE_OVERRIDES.route_rule_changes, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  route_rule_changes: [
    `CREATE TABLE IF NOT EXISTS route_rule_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       name TEXT NOT NULL,
       before_json TEXT,
       after_json TEXT,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_route_rule_changes_name ON route_rule_changes(name, at)",
  ],
};
