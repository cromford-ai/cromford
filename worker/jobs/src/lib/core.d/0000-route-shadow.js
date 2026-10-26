// Frozen baseline: CREATED_TABLE_OVERRIDES.route_shadow, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  route_shadow: [
    `CREATE TABLE IF NOT EXISTS route_shadow (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       build TEXT NOT NULL,
       job_id TEXT,
       project TEXT NOT NULL,
       ticket_key TEXT,
       rule TEXT,
       bumped TEXT,
       would_execute_role TEXT,
       would_execute_model TEXT,
       actual_execute_model TEXT,
       would_review_tier TEXT,
       planned_review_tier TEXT,
       review_model TEXT,
       would_test_scope TEXT,
       differs INTEGER NOT NULL DEFAULT 0,
       features_json TEXT,
       box TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_route_shadow_build ON route_shadow(build)",
    "CREATE INDEX IF NOT EXISTS idx_route_shadow_at ON route_shadow(at, project)",
    "CREATE INDEX IF NOT EXISTS idx_route_shadow_job ON route_shadow(job_id)",
  ],
};
