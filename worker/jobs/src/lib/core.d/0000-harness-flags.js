// Frozen baseline: CREATED_TABLE_OVERRIDES.harness_flags, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-4153: the ported flag families' rows (schema.sql carries the same
  // statements, and test/flags-db.bh-4153.test.js compares them). The third
  // statement is the one-time backfill from pause_flags: INSERT OR IGNORE (the
  // schema-additive lint's form) makes every later run a no-op, so it is safe
  // on each cold isolate.
  harness_flags: [
    `CREATE TABLE IF NOT EXISTS harness_flags (
  scope TEXT NOT NULL DEFAULT 'fleet', name TEXT NOT NULL, value TEXT,
  set_by TEXT, reason TEXT, set_at TEXT NOT NULL, cleared_at TEXT,
  PRIMARY KEY (scope, name))`,
    "CREATE INDEX IF NOT EXISTS harness_flags_name ON harness_flags(name)",
    `INSERT OR IGNORE INTO harness_flags (scope, name, value, set_by, reason, set_at, cleared_at)
  SELECT 'fleet', name, NULL, actor, reason, updated_at, CASE WHEN active=1 THEN NULL ELSE updated_at END
    FROM pause_flags WHERE name LIKE 'paused-%' OR name = 'automerge-disabled' OR name LIKE 'automerge-disabled-%' OR name LIKE 'lanedown-%'`,
  ],
};
