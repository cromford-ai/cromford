// Frozen baseline: CREATED_TABLE_OVERRIDES.route_rules, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // P4 — the self-create copies of schema.sql's route_rules / route_rule_changes
  // / route_shadow blocks, column for column (test/route-rules.p4.test.js pins
  // the parity). The seed rows live only in schema.sql: a table this belt
  // created before harness-sync's apply is an empty rule set, which the shadow
  // resolver reads as "no rule matched" — the same as the live build.
  route_rules: [
    `CREATE TABLE IF NOT EXISTS route_rules (
       name TEXT PRIMARY KEY,
       priority INTEGER NOT NULL,
       effect TEXT NOT NULL,
       mode TEXT NOT NULL,
       match_json TEXT NOT NULL,
       execute_role TEXT,
       review_tier TEXT,
       test_scope TEXT,
       tier_bump INTEGER NOT NULL DEFAULT 0,
       note TEXT,
       version INTEGER NOT NULL DEFAULT 1,
       updated_by TEXT,
       updated_at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_route_rules_priority ON route_rules(priority)",
  ],
};
