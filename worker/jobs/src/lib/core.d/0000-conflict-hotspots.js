// Frozen baseline: CREATED_TABLE_OVERRIDES.conflict_hotspots, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5267 — each project's conflict hotspots and its latest measuring run
  // (routes/conflict-hotspots.js). schema.sql's DDL verbatim, self-created for
  // the BH-1043 reason above; test/conflict-hotspots-route.test.js compares them.
  conflict_hotspots: [
    `CREATE TABLE IF NOT EXISTS conflict_hotspots (
       project TEXT NOT NULL,
       file TEXT NOT NULL,
       conflicts INTEGER NOT NULL,
       rebases INTEGER NOT NULL,
       prs TEXT,
       window_days INTEGER NOT NULL,
       since TEXT NOT NULL,
       until TEXT NOT NULL,
       ref_sha TEXT,
       run_at TEXT NOT NULL,
       PRIMARY KEY (project, file)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_conflict_hotspots_rank ON conflict_hotspots(project, conflicts DESC, rebases DESC, file)",
  ],
};
