// Frozen baseline: CREATED_TABLE_OVERRIDES.lead_protected_paths, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-4146 — the self-create copy of schema.sql's lead_protected_paths block
  // (BH-4140.1), statement for statement. No triggers: a remove is an UPDATE
  // of removed_at; routes/lead-protected-paths.js has no DELETE.
  lead_protected_paths: [
    "CREATE TABLE IF NOT EXISTS lead_protected_paths (id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, glob TEXT NOT NULL, added_by TEXT NOT NULL, added_at TEXT NOT NULL, removed_at TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS lpp_live ON lead_protected_paths(repo, glob) WHERE removed_at IS NULL",
  ],
};
