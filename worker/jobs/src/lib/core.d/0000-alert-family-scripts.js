// Frozen baseline: CREATED_TABLE_OVERRIDES.alert_family_scripts, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-2575 (BH-2544.3): the family→script registry the /api/alert-family-scripts
  // route reads and writes. Self-creates for the same reason as the rest of this
  // map (the deploy is `wrangler deploy`), and
  // test/alert-family-scripts.bh-2544.test.js compares the result with schema.sql.
  alert_family_scripts: [
    `CREATE TABLE IF NOT EXISTS alert_family_scripts (
       id TEXT PRIMARY KEY,
       match_kind TEXT NOT NULL CHECK (match_kind IN ('akey_prefix','line_regex')),
       match TEXT NOT NULL,
       verify TEXT,
       on_clear TEXT NOT NULL DEFAULT 'settle' CHECK (on_clear IN ('settle','model')),
       on_repro TEXT NOT NULL DEFAULT 'model' CHECK (on_repro IN ('model','park')),
       enabled INTEGER NOT NULL DEFAULT 1,
       priority INTEGER NOT NULL DEFAULT 100,
       note TEXT, actor TEXT, updated_at TEXT NOT NULL)`,
    "CREATE INDEX IF NOT EXISTS idx_alert_family_scripts_enabled_priority ON alert_family_scripts(enabled, priority)",
  ],
};
