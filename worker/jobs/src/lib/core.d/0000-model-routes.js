// Frozen baseline: CREATED_TABLE_OVERRIDES.model_routes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1510.0 — the same belt as pr_state_events above: `wrangler deploy` is
  // the whole deploy, so a route reached before harness-sync.sh's own schema
  // apply must still create its table rather than 503 for however long that
  // gap lasts. Column for column with worker/jobs/schema.sql's block — that
  // file is the comment, this is the copy the routes actually run against.
  model_routes: [
    `CREATE TABLE IF NOT EXISTS model_routes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       scope TEXT NOT NULL,
       project TEXT,
       role TEXT NOT NULL,
       position INTEGER NOT NULL,
       model TEXT NOT NULL,
       runner TEXT NOT NULL,
       updated_by TEXT,
       updated_at TEXT NOT NULL
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_model_routes_key ON model_routes(coalesce(project,''), role, position)",
    "CREATE INDEX IF NOT EXISTS idx_model_routes_role ON model_routes(role, project)",
  ],
};
